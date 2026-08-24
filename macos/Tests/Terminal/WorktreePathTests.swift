import Foundation
@testable import Ghostty
import Testing

/// Where `WorktreePath` puts a new worktree.
///
/// Two things here can only be checked against a filesystem: whether the
/// folder a worktree wants already belongs to a different repository of the
/// same name, and whether it is free. Both are built as plain directories
/// and files — the same layouts `GitCommonDir` reads — because the
/// derivation runs no git either.
struct WorktreePathTests {
    private final class Tree {
        let root: String

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-wtpath-\(UUID().uuidString)")
                .path
            directory("")
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

        func file(_ relative: String, _ contents: String) {
            let full = path(relative)
            directory((relative as NSString).deletingLastPathComponent)
            try? contents.write(toFile: full, atomically: true, encoding: .utf8)
        }

        /// A worktree folder pointing, through the layout git writes, at a
        /// main checkout of its own.
        func linkedWorktree(at worktree: String, of checkout: String) {
            directory("\(checkout)/.git/worktrees/w")
            file("\(checkout)/.git/worktrees/w/commondir", "../..\n")
            directory(worktree)
            file("\(worktree)/.git", "gitdir: \(path("\(checkout)/.git/worktrees/w"))\n")
        }
    }

    // MARK: Derivation

    @Test func namesTheFolderAfterTheRepositoryAndTheBranch() {
        let derived = WorktreePath.derive(
            managedRoot: "/Users/dev/.phantom/worktrees",
            mainCheckout: "/Users/dev/Projects/phantom",
            branch: "feat-worktrees"
        )

        #expect(derived == "/Users/dev/.phantom/worktrees/phantom-feat-worktrees")
    }

    /// A branch name is not a path. Left verbatim, `feature/x` would nest an
    /// `x` inside a `feature` folder, `feature/y` would land beside it, and
    /// the one-directory-per-worktree layout the whole pane assumes would be
    /// gone.
    @Test func flattensSlashesInTheBranchName() {
        let derived = WorktreePath.derive(
            managedRoot: "/Users/dev/.phantom/worktrees",
            mainCheckout: "/Users/dev/Projects/phantom",
            branch: "feature/nested/name"
        )

        #expect(derived == "/Users/dev/.phantom/worktrees/phantom-feature-nested-name")
        #expect(WorktreePath.sanitize("feature/x") == "feature-x")
        #expect(WorktreePath.sanitize("main") == "main")
    }

    /// A trailing separator on the checkout must not swallow the repository
    /// name and produce a folder called `-main`.
    @Test func derivesTheRepositoryNameFromTheLastComponent() {
        let derived = WorktreePath.derive(
            managedRoot: "/Users/dev/.phantom/worktrees",
            mainCheckout: "/Users/dev/Projects/my-app/",
            branch: "main"
        )

        #expect(derived == "/Users/dev/.phantom/worktrees/my-app-main")
        #expect(WorktreePath.repoName(mainCheckout: "/Users/dev/Projects/my-app/")
            == "my-app")
    }

    /// The prompt is why the layout is flat: a shell shows the last path
    /// component, and the composite one names the project. Pinned because
    /// the nested layout this replaced said only the branch, leaving "which
    /// project" unanswered dozens of times a day.
    @Test func theFolderNameCarriesBothFactsForThePrompt() {
        let name = WorktreePath.folderName(
            mainCheckout: "/Users/dev/Projects/react-ts", branch: "feat/new-menu")

        #expect(name == "react-ts-feat-new-menu")
    }

    /// The repository name is read off the checkout, never parsed back out
    /// of the folder name: `api-v2` with branch `fix` composes `api-v2-fix`,
    /// and splitting on dashes cannot know where the repository stops.
    @Test func theRepositoryNameIsReadNotParsed() {
        #expect(WorktreePath.folderName(
            mainCheckout: "/Users/dev/Projects/api-v2", branch: "fix") == "api-v2-fix")
        #expect(WorktreePath.repoName(mainCheckout: "/Users/dev/Projects/api-v2") == "api-v2")
    }

    // MARK: Collisions

    /// A second worktree of the same project takes its own folder and does
    /// not disturb the first — the ordinary second `git worktree add`.
    @Test func aSecondWorktreeOfTheSameRepositoryGetsItsOwnFolder() {
        let tree = Tree()
        let checkout = tree.path("Projects/phantom")
        tree.linkedWorktree(at: "worktrees/phantom-feat-a", of: "Projects/phantom")

        let derived = WorktreePath.derive(
            managedRoot: tree.path("worktrees"),
            mainCheckout: checkout,
            branch: "feat-b"
        )

        #expect(derived == tree.path("worktrees/phantom-feat-b"))
    }

    /// Asking twice for the same branch answers the same folder, because
    /// that folder is this repository's own — the flow then lets git refuse
    /// if it is occupied, which is a better message than a silent `-2`.
    @Test func theSameBranchResolvesBackToItsOwnFolder() {
        let tree = Tree()
        tree.linkedWorktree(at: "worktrees/phantom-feat-a", of: "Projects/phantom")

        let derived = WorktreePath.derive(
            managedRoot: tree.path("worktrees"),
            mainCheckout: tree.path("Projects/phantom"),
            branch: "feat-a"
        )

        #expect(derived == tree.path("worktrees/phantom-feat-a"))
    }

    /// Repository names are not unique — a fork and its upstream are both
    /// called `phantom`, and with a flat layout their `phantom-feat-a`
    /// folders want the same name. The second one moves aside.
    @Test func suffixesTheFolderWhenItBelongsToADifferentRepository() {
        let tree = Tree()
        tree.linkedWorktree(at: "worktrees/phantom-feat-a", of: "Projects/phantom")

        let derived = WorktreePath.derive(
            managedRoot: tree.path("worktrees"),
            mainCheckout: tree.path("Forks/phantom"),
            branch: "feat-a"
        )

        #expect(derived == tree.path("worktrees/phantom-feat-a-2"))
    }

    /// And keeps counting when `-2` is somebody else's too.
    @Test func keepsCountingPastTheFirstSuffix() {
        let tree = Tree()
        tree.linkedWorktree(at: "worktrees/phantom-feat-a", of: "Projects/phantom")
        tree.linkedWorktree(at: "worktrees/phantom-feat-a-2", of: "Forks/phantom")

        let derived = WorktreePath.derive(
            managedRoot: tree.path("worktrees"),
            mainCheckout: tree.path("Mirrors/phantom"),
            branch: "feat-a"
        )

        #expect(derived == tree.path("worktrees/phantom-feat-a-3"))
    }

    /// An existing folder that can't say who it belongs to — empty, or
    /// holding something that isn't a worktree — is claimed rather than
    /// stepped over. There is no evidence against it, and a `-2` sitting
    /// beside an empty `phantom` folder is the worse of the two mistakes.
    @Test func claimsAFolderThatAnswersNothing() {
        let tree = Tree()
        tree.directory("worktrees/phantom-feat-b/notes")

        let derived = WorktreePath.derive(
            managedRoot: tree.path("worktrees"),
            mainCheckout: tree.path("Projects/phantom"),
            branch: "feat-b"
        )

        #expect(derived == tree.path("worktrees/phantom-feat-b"))
    }

    // MARK: isOccupied

    @Test func anAbsentPathIsFree() {
        let tree = Tree()

        #expect(!WorktreePath.isOccupied(tree.path("worktrees/phantom-feat-b")))
    }

    @Test func anEmptyDirectoryIsFree() {
        let tree = Tree()
        tree.directory("worktrees/phantom-feat-b")

        #expect(!WorktreePath.isOccupied(tree.path("worktrees/phantom-feat-b")))
    }

    /// Hidden children count. A folder holding nothing but the `.DS_Store`
    /// Finder left behind is still one git refuses, so calling it free would
    /// buy a friendlier message followed by the failure it promised
    /// wouldn't happen.
    @Test func aDirectoryHoldingOnlyAHiddenFileIsOccupied() {
        let tree = Tree()
        tree.file("worktrees/phantom-feat-b/.DS_Store", "")

        #expect(WorktreePath.isOccupied(tree.path("worktrees/phantom-feat-b")))
    }

    /// A file where the worktree should go is as occupied as it gets: git
    /// cannot check out into it, and nothing can be created beneath it.
    @Test func aFileAtThePathIsOccupied() {
        let tree = Tree()
        tree.file("worktrees/phantom-feat-b", "not a directory")

        #expect(WorktreePath.isOccupied(tree.path("worktrees/phantom-feat-b")))
    }

    /// The derivation returns the path either way. Git's own check is
    /// stricter than any of this and is the one that decides; `isOccupied`
    /// only exists so the flow can say something kinder first.
    @Test func derivationStillReturnsAnOccupiedPath() {
        let tree = Tree()
        tree.file("worktrees/phantom-feat-b/leftover.txt", "hi")

        let derived = WorktreePath.derive(
            managedRoot: tree.path("worktrees"),
            mainCheckout: tree.path("Projects/phantom"),
            branch: "feat-b"
        )

        #expect(derived == tree.path("worktrees/phantom-feat-b"))
        #expect(WorktreePath.isOccupied(derived))
    }
}

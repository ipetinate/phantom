import Foundation
@testable import Ghostty
import Testing

/// `GitCommonDir.resolve` against the layouts git writes, built by hand.
///
/// Built by hand deliberately: the resolver's contract is that it never runs
/// git, so the fixtures are the files it reads and nothing else. A real
/// repository would pass these tests even if the code quietly grew a
/// `rev-parse` call, and that call is the one thing that must not appear —
/// this resolver sits on the sidebar's 5s timer path.
///
/// Every layout below is what `git worktree add` and `git submodule` leave
/// on disk: a `.git` file naming an administrative directory, and a
/// `commondir` file in that directory naming the shared git directory.
struct GitCommonDirTests {
    /// A throwaway tree of plain directories and files.
    private final class Tree {
        let root: String

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-commondir-\(UUID().uuidString)")
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

        /// The same directory, spelled the way git spells it: the temporary
        /// directory sits behind a symlink, and git resolves it. Same call
        /// as `EditorFolderRepathTests`' `workspace()`.
        static func real(_ path: String) -> String {
            var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
            guard realpath(path, &buffer) != nil else { return path }
            return String(cString: buffer)
        }
    }

    // MARK: The main checkout

    /// A `.git` directory means this folder *is* the main checkout, and the
    /// answer is itself — no file to read, no pointer to follow.
    @Test func aDotGitDirectoryIsTheMainCheckout() {
        let tree = Tree()
        tree.directory("repo/.git")

        #expect(GitCommonDir.resolve(from: tree.path("repo")) == tree.path("repo"))
    }

    @Test func aFolderWithNoDotGitHasNoCommonDir() {
        let tree = Tree()
        tree.directory("plain")

        #expect(GitCommonDir.resolve(from: tree.path("plain")) == nil)
    }

    @Test func anEmptyRootHasNoCommonDir() {
        #expect(GitCommonDir.resolve(from: "") == nil)
    }

    // MARK: Linked worktrees

    /// The layout `git worktree add` writes when the pair was moved or
    /// `--relative-paths` was asked for: both pointers relative, the
    /// `gitdir:` one relative to the worktree and `commondir` relative to
    /// the administrative directory.
    @Test func followsRelativePointersToTheMainCheckout() {
        let tree = Tree()
        tree.directory("repo/.git")
        tree.directory("repo/.git/worktrees/feat-x")
        tree.file("repo/.git/worktrees/feat-x/commondir", "../..\n")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: ../../repo/.git/worktrees/feat-x\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == tree.path("repo"))
    }

    /// The layout git writes by default: an absolute `gitdir:`.
    @Test func followsAnAbsolutePointerToTheMainCheckout() {
        let tree = Tree()
        tree.directory("repo/.git/worktrees/feat-x")
        tree.file("repo/.git/worktrees/feat-x/commondir", tree.path("repo/.git") + "\n")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: \(tree.path("repo/.git/worktrees/feat-x"))\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == tree.path("repo"))
    }

    /// `commondir` is the authority, so when it disagrees with the layout it
    /// wins — this is what makes a worktree whose repository was moved and
    /// then repaired still resolve.
    @Test func commondirWinsOverTheLayout() {
        let tree = Tree()
        tree.directory("moved/.git")
        tree.directory("repo/.git/worktrees/feat-x")
        tree.file("repo/.git/worktrees/feat-x/commondir", tree.path("moved/.git") + "\n")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: \(tree.path("repo/.git/worktrees/feat-x"))\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == tree.path("moved"))
    }

    /// No `commondir` at all — an old git, or a half-copied repository. The
    /// standard layout still says where the shared git directory is, because
    /// the administrative directory is inside it.
    @Test func fallsBackToTheLayoutWhenCommondirIsMissing() {
        let tree = Tree()
        tree.directory("repo/.git/worktrees/feat-x")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: \(tree.path("repo/.git/worktrees/feat-x"))\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == tree.path("repo"))
    }

    @Test func aDotGitFileThatIsNotAPointerResolvesToNothing() {
        let tree = Tree()
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "this is not a git file\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == nil)
    }

    // MARK: Bare repositories

    /// A bare repository's shared git directory is the repository, not
    /// something with a `.git` inside a checkout. There is no `.git` suffix
    /// to strip, so the common directory is returned as it stands and
    /// callers read that as bare.
    @Test func aBareRepositoryResolvesToItsOwnGitDirectory() {
        let tree = Tree()
        tree.directory("mirror/phantom.git/worktrees/feat-x")
        tree.file("mirror/phantom.git/worktrees/feat-x/commondir", "../..\n")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: \(tree.path("mirror/phantom.git/worktrees/feat-x"))\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == tree.path("mirror/phantom.git"))
    }

    /// And with no `commondir` to follow, the layout fallback deliberately
    /// declines: `phantom.git/worktrees/` has no `.git` component, and
    /// inventing one would name a checkout that does not exist.
    @Test func aBareLayoutWithNoCommondirResolvesToNothing() {
        let tree = Tree()
        tree.directory("mirror/phantom.git/worktrees/feat-x")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: \(tree.path("mirror/phantom.git/worktrees/feat-x"))\n")

        #expect(GitCommonDir.resolve(from: tree.path("wt/feat-x")) == nil)
    }

    // MARK: Spelling

    /// The answer comes back spelled exactly as it was asked for.
    ///
    /// Foundation's path standardisation — `URL.standardizedFileURL` and
    /// `NSString.standardizingPath` alike — rewrites `/private/var/…` to
    /// `/var/…`: the same directory under a different name. This resolver's
    /// answer is the key that git's worktree paths and the tabs' working
    /// directories are matched against, and git prints the `/private` form.
    /// A restyled key matches nothing, so the repository is listed twice and
    /// the worktree belongs to neither entry.
    ///
    /// The regression this pins was real, and only a test against a path
    /// actually behind a symlink could see it — every hand-built fixture
    /// above uses the unresolved spelling and passed throughout.
    @Test func doesNotRestyleThePathItIsGiven() throws {
        let tree = Tree()
        let real = Tree.real(tree.root)
        try #require(real != tree.root, "the temporary directory is expected to sit behind a symlink")

        tree.directory("repo/.git/worktrees/feat-x")
        tree.file("repo/.git/worktrees/feat-x/commondir", "../..\n")
        tree.directory("wt/feat-x")
        tree.file("wt/feat-x/.git", "gitdir: \(real)/repo/.git/worktrees/feat-x\n")

        #expect(GitCommonDir.resolve(from: "\(real)/wt/feat-x") == "\(real)/repo")
    }

    // MARK: Submodules

    /// A submodule's `.git` file has the same shape as a worktree's, and
    /// following it would answer with the superproject — a different
    /// repository, with a different object store and a worktree list of its
    /// own. The pane would then show the superproject's worktrees under the
    /// submodule's name.
    @Test func aSubmoduleHasNoCommonDirOfItsOwn() {
        let tree = Tree()
        tree.directory("repo/.git/modules/vendor/lib")
        tree.file("repo/.git/modules/vendor/lib/commondir", "../../../..\n")
        tree.directory("repo/vendor/lib")
        tree.file("repo/vendor/lib/.git", "gitdir: ../../.git/modules/vendor/lib\n")

        #expect(GitCommonDir.resolve(from: tree.path("repo/vendor/lib")) == nil)
    }
}

import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Whether a file staged from a git panel row stops to ask first.
///
/// The rule it protects: `git add` on a path with conflict markers still in it
/// tells git the conflict is resolved, and git's refusal to commit unmerged
/// paths was the only thing standing between a half-resolved merge and a
/// commit carrying `<<<<<<< HEAD`.
///
/// `EditorConflictParser` decides what a conflict *is*, and has its own tests.
/// These are about the layer above it — which files are read at all, and what
/// the alert says once one of them blocks.
struct GitConflictStagingTests {
    /// A directory per test, removed with it, so two tests can never see each
    /// other's files.
    private final class Sandbox {
        let root: URL

        init() {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("GitConflictStaging-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ name: String, _ contents: String) -> URL {
            let url = root.appendingPathComponent(name)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func data(_ name: String, _ bytes: Data) -> URL {
            let url = root.appendingPathComponent(name)
            try? bytes.write(to: url)
            return url
        }

        /// Makes the sandbox look like an ordinary checkout, and hands back
        /// the directory git keeps its state in.
        @discardableResult
        func makeCheckout() -> URL {
            let git = root.appendingPathComponent(".git")
            try? FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            return git
        }

        /// Makes it look like a linked worktree instead: `.git` is a file
        /// holding a `gitdir:` line, and the state lives where that points.
        @discardableResult
        func makeLinkedWorktree(relativePointer: Bool = false) -> URL {
            let admin = root.appendingPathComponent("admin/worktrees/feature")
            try? FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)

            let target = relativePointer ? "admin/worktrees/feature" : admin.path
            try? "gitdir: \(target)\n".write(
                to: root.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )
            return admin
        }

        /// Writes one of git's stopped-operation files.
        func mark(_ name: String, in directory: URL) {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path,
                contents: nil
            )
        }
    }

    private static let conflict = """
        func greet() {
        <<<<<<< HEAD
            print("hello")
        =======
            print("hi")
        >>>>>>> feature
        }

        """

    // MARK: Which files block

    @Test func aFileWithAConflictBlocks() {
        let sandbox = Sandbox()
        let url = sandbox.file("main.swift", Self.conflict)

        #expect(GitConflictStaging.conflictCount(at: url) == 1)
    }

    @Test func everyConflictInTheFileIsCounted() {
        let sandbox = Sandbox()
        let url = sandbox.file("main.swift", Self.conflict + Self.conflict)

        #expect(GitConflictStaging.conflictCount(at: url) == 2)
    }

    @Test func anOrdinaryFileDoesNotBlock() {
        let sandbox = Sandbox()
        let url = sandbox.file("main.swift", "func greet() {\n    print(\"hello\")\n}\n")

        #expect(GitConflictStaging.conflictCount(at: url) == 0)
    }

    /// A staged deletion keeps its row, and the row keeps its Stage item.
    /// There is nothing on disk to read, and asking the reader about a file
    /// that is gone would be a question with no answer.
    @Test func aPathThatIsNotThereDoesNotBlock() {
        let sandbox = Sandbox()

        #expect(GitConflictStaging.conflictCount(at: sandbox.root.appendingPathComponent("gone.swift")) == 0)
    }

    /// Git reports an untracked directory as one row, so `+` can point at a
    /// folder. Reading it fails rather than needing a rule of its own.
    @Test func aDirectoryDoesNotBlock() {
        let sandbox = Sandbox()
        let url = sandbox.root.appendingPathComponent("vendor")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(GitConflictStaging.conflictCount(at: url) == 0)
    }

    /// Bytes that are not UTF-8 — an image, a compiled artefact — cannot be
    /// decoded, and a conflict git wrote is text by definition.
    @Test func aBinaryFileDoesNotBlock() {
        let sandbox = Sandbox()
        let url = sandbox.data("logo.png", Data([0xFF, 0xFE, 0x00, 0x80, 0x91, 0xC0]))

        #expect(GitConflictStaging.conflictCount(at: url) == 0)
    }

    /// The read sits between a click and the thing the click does, so a file
    /// past the cap is staged without being read. The markers here are real —
    /// the size is the whole reason this returns zero.
    @Test func aFileOverTheSizeCapIsNotRead() {
        let sandbox = Sandbox()
        let padding = String(repeating: "x", count: GitConflictStaging.maxBytesToScan)
        let url = sandbox.file("huge.log", Self.conflict + padding)

        #expect(GitConflictStaging.conflictCount(at: url) == 0)
    }

    /// The same content just under the cap still blocks, which is what says
    /// the test above measured the size and not something else.
    @Test func aFileUnderTheSizeCapIsRead() {
        let sandbox = Sandbox()
        let room = GitConflictStaging.maxBytesToScan - Self.conflict.utf8.count - 1
        let url = sandbox.file("large.log", Self.conflict + String(repeating: "x", count: room))

        #expect(GitConflictStaging.conflictCount(at: url) == 1)
    }

    // MARK: What the reader is asked

    /// The alert arrives over a list of rows, so it has to say which one it is
    /// about — the file's name, not its path, which is what the row shows.
    @Test func theQuestionNamesTheFile() {
        #expect(GitConflictStaging.question(for: "EditorGridView.swift")
            == "Stage \u{201C}EditorGridView.swift\u{201D} with its conflict markers?")
    }

    /// Both halves are load-bearing: what is still in the file, and what git
    /// stops doing once it is staged.
    @Test func theExplanationSaysWhatStagingCosts() {
        let text = GitConflictStaging.explanation(conflicts: 1)

        #expect(text.contains("an unresolved conflict"))
        #expect(text.contains("<<<<<<<"))
        #expect(text.contains("the markers go into history"))
    }

    @Test func theExplanationCountsMoreThanOneConflict() {
        let text = GitConflictStaging.explanation(conflicts: 3)

        #expect(text.contains("3 unresolved conflicts"))
        #expect(!text.contains("an unresolved conflict"))
    }

    // MARK: Whether git has anything stopped

    @Test func anOrdinaryCheckoutHasNoUnfinishedMerge() {
        let sandbox = Sandbox()
        sandbox.makeCheckout()

        #expect(!GitConflictStaging.hasUnfinishedMerge(at: sandbox.root.path))
    }

    @Test func aFolderThatIsNotARepositoryHasNoUnfinishedMerge() {
        let sandbox = Sandbox()

        #expect(!GitConflictStaging.hasUnfinishedMerge(at: sandbox.root.path))
        #expect(GitConflictStaging.gitDirectory(at: sandbox.root.path) == nil)
    }

    /// All four, because each one leaves a working tree that can hold markers
    /// and only the file's name differs.
    @Test(arguments: ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"])
    func aStoppedOperationIsAnUnfinishedMerge(_ marker: String) {
        let sandbox = Sandbox()
        sandbox.mark(marker, in: sandbox.makeCheckout())

        #expect(GitConflictStaging.hasUnfinishedMerge(at: sandbox.root.path))
    }

    /// Git keeps `MERGE_HEAD` beside each worktree's own `HEAD`, so a linked
    /// worktree's state has to be read through its `gitdir:` pointer. Reading
    /// the family's main checkout instead would answer another worktree's
    /// question.
    @Test func aLinkedWorktreeIsReadThroughItsPointer() {
        let sandbox = Sandbox()
        let admin = sandbox.makeLinkedWorktree()

        #expect(!GitConflictStaging.hasUnfinishedMerge(at: sandbox.root.path))

        sandbox.mark("MERGE_HEAD", in: admin)
        #expect(GitConflictStaging.hasUnfinishedMerge(at: sandbox.root.path))
    }

    /// Git writes the pointer relative to the working tree when the pair was
    /// moved or `--relative-paths` was asked for.
    @Test func aRelativePointerResolvesAgainstTheWorkingTree() {
        let sandbox = Sandbox()
        let admin = sandbox.makeLinkedWorktree(relativePointer: true)
        sandbox.mark("CHERRY_PICK_HEAD", in: admin)

        #expect(GitConflictStaging.hasUnfinishedMerge(at: sandbox.root.path))
    }

    // MARK: What a repository-wide stage asks about

    /// The gate the whole design rests on. Markers exist only while git has an
    /// operation stopped, so with nothing stopped this answers without reading
    /// a file — the file below would block, and does in the next test.
    @Test func nothingBlocksWhenGitHasNothingStopped() {
        let sandbox = Sandbox()
        sandbox.makeCheckout()
        _ = sandbox.file("main.swift", Self.conflict)

        #expect(GitConflictStaging.blockers(among: ["main.swift"], in: sandbox.root.path).isEmpty)
    }

    /// The gap this closes: the reader resolved one of three conflicts and
    /// staged the file, so git no longer calls the path unmerged — but two
    /// blocks are still in it, and Stage All would put them in the index.
    @Test func aPartlyResolvedFileBlocksDuringAMerge() {
        let sandbox = Sandbox()
        sandbox.mark("MERGE_HEAD", in: sandbox.makeCheckout())
        _ = sandbox.file("main.swift", Self.conflict + "\nfunc done() {}\n" + Self.conflict)

        #expect(GitConflictStaging.blockers(among: ["main.swift"], in: sandbox.root.path)
            == [GitConflictStaging.ConflictedFile(name: "main.swift", conflicts: 2)])
    }

    /// Only the files that still hold markers are named, and by the name the
    /// panel's row shows rather than by the path git prints.
    @Test func onlyTheFilesThatStillHoldMarkersAreNamed() {
        let sandbox = Sandbox()
        sandbox.mark("REBASE_HEAD", in: sandbox.makeCheckout())

        let nested = sandbox.root.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = sandbox.file("src/main.swift", Self.conflict)
        _ = sandbox.file("README.md", "# Title\n=======\nstill prose\n")

        let blocked = GitConflictStaging.blockers(
            among: ["src/main.swift", "README.md", "gone.swift"],
            in: sandbox.root.path
        )

        #expect(blocked.map(\.name) == ["main.swift"])
    }

    // MARK: Answering

    /// Cancelling stages nothing, and neither does a sheet that ends without
    /// an answer because its window closed under it.
    @Test func onlyTheFirstButtonStages() {
        #expect(GitConflictStaging.stages(.alertFirstButtonReturn))
        #expect(!GitConflictStaging.stages(.alertSecondButtonReturn))
        #expect(!GitConflictStaging.stages(.cancel))
        #expect(!GitConflictStaging.stages(.abort))
    }

    // MARK: What several files are called

    @Test func theQuestionForSeveralFilesCountsThem() {
        #expect(GitConflictStaging.question(fileCount: 4)
            == "Stage 4 files that still hold conflict markers?")
    }

    @Test func twoNamesAreJoinedWithAnd() {
        #expect(GitConflictStaging.listed(["a.swift", "b.swift"]) == "a.swift and b.swift")
    }

    @Test func threeNamesAreAList() {
        #expect(GitConflictStaging.listed(["a.swift", "b.swift", "c.swift"])
            == "a.swift, b.swift and c.swift")
    }

    /// Past the cap the alert counts instead of listing, so a merge that left
    /// dozens does not produce a paragraph the reader skips.
    @Test func pastTheCapTheRestAreCounted() {
        let names = (1...9).map { "file\($0).swift" }

        #expect(GitConflictStaging.listed(names)
            == "file1.swift, file2.swift, file3.swift and 6 more")
    }

    @Test func theExplanationForSeveralFilesNamesThemAndTheCost() {
        let text = GitConflictStaging.explanation(for: ["a.swift", "b.swift"])

        #expect(text.hasPrefix("a.swift and b.swift still hold"))
        #expect(text.contains("<<<<<<<"))
        #expect(text.contains("the markers go into history"))
    }
}

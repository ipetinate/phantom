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
}

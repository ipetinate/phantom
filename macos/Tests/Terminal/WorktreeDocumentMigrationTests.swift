import Foundation
@testable import Ghostty
import Testing

/// What the open editor tabs do when their terminal switches worktrees.
///
/// Built against real directories because the one thing that cannot be
/// reasoned about is whether the other branch has the file: that is a
/// question for the filesystem, and it is the question that separates a tab
/// that follows from a tab that goes read-only.
struct WorktreeDocumentMigrationTests {
    private final class Trees {
        let root: String

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-wtmig-\(UUID().uuidString)")
                .path
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        func path(_ relative: String) -> String {
            (root as NSString).appendingPathComponent(relative)
        }

        /// A file, and every folder above it.
        @discardableResult
        func file(_ relative: String, _ contents: String = "x") -> String {
            let full = path(relative)
            try? FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? contents.write(toFile: full, atomically: true, encoding: .utf8)
            return full
        }
    }

    // MARK: The four answers

    /// The ordinary case, and the one the whole flow exists for.
    @Test func aCleanFileThatExistsOnTheOtherSideFollows() {
        let trees = Trees()
        let open = trees.file("a/src/main.swift")
        trees.file("b/src/main.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: false)],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan == [.migrate(from: open, to: trees.path("b/src/main.swift"))])
    }

    /// Unsaved edits were written against this checkout. Carrying the buffer
    /// to the other one and saving would write one branch's work into
    /// another branch's file with nothing on screen having said so.
    @Test func aDirtyFileStaysEvenWhenTheOtherSideHasIt() {
        let trees = Trees()
        let open = trees.file("a/src/main.swift")
        trees.file("b/src/main.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: true)],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan == [.stayDirty(path: open)])
    }

    /// Added on the branch the tab is already on. Reopening at the missing
    /// path would show an empty buffer that saves the file into existence.
    @Test func aCleanFileTheOtherSideDoesNotHaveStays() {
        let trees = Trees()
        let open = trees.file("a/src/OnlyHere.swift")
        trees.file("b/src/main.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: false)],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan == [.stayMissing(path: open)])
    }

    /// Dirty wins over missing. A buffer the reader is still typing into
    /// must not be described as a read-only file that does not exist.
    @Test func dirtyIsAnsweredBeforeTheDestinationIsLookedFor() {
        let trees = Trees()
        let open = trees.file("a/src/OnlyHere.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: true)],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan == [.stayDirty(path: open)])
    }

    /// A file open from another repository is not part of this switch, and
    /// listing it would ask the reader to decide about something that is not
    /// changing.
    @Test func aFileFromSomewhereElseIsUnrelated() {
        let trees = Trees()
        let outside = trees.file("elsewhere/notes.md")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: outside, isDirty: true)],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan == [.unrelated(path: outside)])
    }

    // MARK: Path arithmetic

    /// The relative path is what carries over, however deep it goes.
    @Test func theRelativePathIsPreservedThroughDeepFolders() {
        let trees = Trees()
        let open = trees.file("a/src/Features/Terminal/Sidebar/Worktrees/View.swift")
        trees.file("b/src/Features/Terminal/Sidebar/Worktrees/View.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: false)],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan == [.migrate(
            from: open,
            to: trees.path("b/src/Features/Terminal/Sidebar/Worktrees/View.swift"))])
    }

    /// The boundary that the flat layout makes routine rather than rare.
    ///
    /// `<repo>-<branch>` puts `react-ts-main` and `react-ts-main-2` side by
    /// side in one folder, so a prefix comparison that ignores the component
    /// boundary would read every file of the first as belonging to the
    /// second — and migrate a whole window's worth of tabs to paths that
    /// don't exist.
    @Test func aSiblingWorktreeWhoseNameStartsTheSameIsNotThisOne() {
        let trees = Trees()
        let open = trees.file("react-ts-main-2/src/main.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: false)],
            from: trees.path("react-ts-main"),
            to: trees.path("react-ts-feat-x")
        )

        #expect(plan == [.unrelated(path: open)])
    }

    /// A trailing separator on either root is the same root.
    @Test func aTrailingSlashDoesNotChangeTheAnswer() {
        let trees = Trees()
        let open = trees.file("a/main.swift")
        trees.file("b/main.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: false)],
            from: trees.path("a") + "/",
            to: trees.path("b") + "/"
        )

        #expect(plan == [.migrate(from: open, to: trees.path("b/main.swift"))])
    }

    // MARK: Nothing to do

    @Test func noDocumentsIsNoWork() {
        let trees = Trees()

        #expect(WorktreeDocumentMigration.plan(
            documents: [], from: trees.path("a"), to: trees.path("b")).isEmpty)
    }

    /// Switching to where the terminal already is closes and reopens every
    /// tab to arrive exactly where it started. Answered as no work at all
    /// rather than as a migration from a path to itself.
    @Test func migratingToTheSameWorktreeIsNoWork() {
        let trees = Trees()
        let open = trees.file("a/main.swift")

        #expect(WorktreeDocumentMigration.plan(
            documents: [(path: open, isDirty: false)],
            from: trees.path("a"),
            to: trees.path("a") + "/").isEmpty)
    }

    /// An absent root cannot own anything, so nothing is claimed and nothing
    /// is moved — the safe answer for a panel that can be asked before git
    /// has answered.
    @Test func anEmptyRootProducesNoWork() {
        let trees = Trees()
        let open = trees.file("a/main.swift")
        let documents = [(path: open, isDirty: false)]

        #expect(WorktreeDocumentMigration.plan(
            documents: documents, from: "", to: trees.path("b")).isEmpty)
        #expect(WorktreeDocumentMigration.plan(
            documents: documents, from: trees.path("a"), to: "").isEmpty)
    }

    // MARK: What the caller asks of the plan

    @Test func theOutcomesKeepTheOrderTheyWereGivenIn() {
        let trees = Trees()
        let follows = trees.file("a/one.swift")
        let dirty = trees.file("a/two.swift")
        let missing = trees.file("a/three.swift")
        let outside = trees.file("elsewhere/four.swift")
        trees.file("b/one.swift")
        trees.file("b/two.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [
                (path: follows, isDirty: false),
                (path: dirty, isDirty: true),
                (path: missing, isDirty: false),
                (path: outside, isDirty: false),
            ],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(plan.map(\.path) == [follows, dirty, missing, outside])
        #expect(WorktreeDocumentMigration.migrations(in: plan).map(\.from) == [follows])
    }

    /// The list the popover shows. A file from another repository is not on
    /// it — it is not changing.
    @Test func onlyTheFilesLeftBehindNeedSaying() {
        let trees = Trees()
        let follows = trees.file("a/one.swift")
        let dirty = trees.file("a/two.swift")
        let missing = trees.file("a/three.swift")
        let outside = trees.file("elsewhere/four.swift")
        trees.file("b/one.swift")

        let plan = WorktreeDocumentMigration.plan(
            documents: [
                (path: follows, isDirty: false),
                (path: dirty, isDirty: true),
                (path: missing, isDirty: false),
                (path: outside, isDirty: true),
            ],
            from: trees.path("a"),
            to: trees.path("b")
        )

        #expect(WorktreeDocumentMigration.staying(in: plan)
            == [.stayDirty(path: dirty), .stayMissing(path: missing)])
    }
}

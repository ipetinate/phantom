import Foundation
@testable import Ghostty
import Testing

/// Entering, cancelling and committing a name in the tree.
///
/// Two bugs live here. Creating inside a *collapsed* folder set `editing`
/// and drew no field: rows are built by walking down from the root through
/// expanded folders only, so the placeholder was never built — and with
/// `editing` set, rename, delete, create and every key the tree answers for
/// became a no-op. Nothing but changing the root could clear it. The other
/// is the commit that arrives after the edit is over, from a field losing
/// focus, which had a cancelled create renaming a file that was never
/// written.
@MainActor
struct FileExplorerEditingTests {
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Listings run off the main actor, so every assertion about rows has to
    /// wait for the ones in flight to land. Bounded, so a directory that
    /// never answers fails the test instead of hanging the suite.
    private func settle(_ model: FileExplorerModel) async {
        for _ in 0..<200 where !model.loading.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func rooted(at base: URL) async -> FileExplorerModel {
        let model = FileExplorerModel()
        model.setRoot(base.path)
        await settle(model)
        return model
    }

    // MARK: Creating inside a collapsed folder

    @Test func creatingInsideACollapsedFolderOpensItAndShowsTheField() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("a.ts"))

        let model = await rooted(at: base)
        #expect(!model.expanded.contains(folder.path), "the folder starts closed")

        model.beginCreate(in: folder.path, isFolder: false)
        await settle(model)

        #expect(model.expanded.contains(folder.path))
        #expect(model.rows.contains { $0.isCreatePlaceholder }, "the field has to be on screen")
    }

    @Test func creatingInsideADeeplyNestedFolderOpensTheWholeWayDown() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let deep = base.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let model = await rooted(at: base)
        model.beginCreate(in: deep.path, isFolder: true)
        await settle(model)

        #expect(model.expanded.contains(base.appendingPathComponent("a").path))
        #expect(model.expanded.contains(base.appendingPathComponent("a/b").path))
        #expect(model.expanded.contains(deep.path))
        #expect(model.rows.contains { $0.isCreatePlaceholder })
    }

    /// The wedge, stated as an invariant: there is never an edit in progress
    /// that no row can show. A folder outside the tree can't be drawn, so
    /// the create is refused rather than entered.
    @Test func aCreateThatCouldNotBeShownIsNeverEntered() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let model = await rooted(at: base)
        model.beginCreate(in: "/somewhere/else", isFolder: false)

        #expect(model.editing == nil)
    }

    @Test func aCreateWithNoRootIsNeverEntered() {
        let model = FileExplorerModel()
        model.beginCreate(in: "/tmp", isFolder: false)

        #expect(model.editing == nil)
    }

    @Test func theTreeIsUsableAgainAfterCancelling() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = await rooted(at: base)
        model.beginCreate(in: folder.path, isFolder: false)
        await settle(model)
        model.cancelEditing()

        #expect(model.editing == nil)
        #expect(!model.rows.contains { $0.isCreatePlaceholder })

        // The proof that nothing is stuck: the next action is accepted.
        model.beginRename(path: folder.path)
        #expect(model.editing == .rename(path: folder.path))
    }

    // MARK: Which edit is live

    @Test func onlyTheEditBeingAskedForIsLive() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let model = await rooted(at: base)
        model.beginCreate(in: base.path, isFolder: false)

        #expect(model.isEditing(.create(parent: base.path, isFolder: false)))
        #expect(!model.isEditing(.create(parent: base.path, isFolder: true)))
        #expect(!model.isEditing(.rename(path: base.path)))
    }

    /// What the view asks before letting a late focus-loss commit through:
    /// after Esc there is no live edit, so the commit is dropped instead of
    /// falling through to a rename of a file that was never created.
    @Test func nothingIsLiveAfterCancelling() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let model = await rooted(at: base)
        model.beginCreate(in: base.path, isFolder: false)
        model.cancelEditing()

        #expect(!model.isEditing(.create(parent: base.path, isFolder: false)))
    }

    @Test func nothingIsLiveAfterCommitting() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let model = await rooted(at: base)
        model.beginCreate(in: base.path, isFolder: false)
        model.commitCreate(parent: base.path, isFolder: false, name: "notes.txt")

        #expect(!model.isEditing(.create(parent: base.path, isFolder: false)))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("notes.txt").path))
    }

    /// The traversal again, through the model this time — the layer the
    /// typed name actually arrives at.
    @Test func committingANameThatClimbsOutOfTheFolderCreatesNothing() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let inside = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        let model = await rooted(at: base)
        model.beginCreate(in: inside.path, isFolder: false)
        await settle(model)
        let result = model.commitCreate(parent: inside.path, isFolder: false, name: "../escape.txt")

        #expect(throws: (any Error).self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.txt").path))
        #expect(model.errorMessage != nil, "the refusal is explained rather than silent")
    }

    // MARK: Dropping

    @Test func droppingSomethingFromOutsideTheTreeCopiesIt() async throws {
        let base = try tempDirectory()
        let elsewhere = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let source = elsewhere.appendingPathComponent("dragged.txt")
        try Data().write(to: source)

        let model = await rooted(at: base)
        let outcome = try model.drop(path: source.path, into: base.path).get()

        #expect(outcome == .copied(base.appendingPathComponent("dragged.txt")))
        #expect(FileManager.default.fileExists(atPath: source.path), "Finder's copy stays put")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("dragged.txt").path))
    }

    @Test func draggingWithinTheTreeStillMoves() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = base.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("a.txt")
        try Data().write(to: source)

        let model = await rooted(at: base)
        let outcome = try model.drop(path: source.path, into: folder.path).get()

        #expect(outcome == .moved(folder.appendingPathComponent("a.txt")))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}

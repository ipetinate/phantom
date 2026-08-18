import Foundation
@testable import Ghostty
import Testing

/// Revealing the file the editor is showing: which folders have to open for
/// its row to exist, and what the tree does with a path it can't place.
///
/// The highlight on the open file was only ever visible when its row happened
/// to be on screen already — a file opened from a search, a definition jump or
/// the Git panel lit up a row inside a folder nobody had expanded, which is to
/// say it lit up nothing.
struct FileExplorerRevealTests {
    private func ancestors(_ path: String, under root: String) -> [String] {
        FileExplorerModel.ancestorsToOpen(revealing: path, under: root)
    }

    // MARK: Which folders open

    /// Outermost first, because that is the order they have to be listed in:
    /// a folder's rows are built by walking down from the root, so a level
    /// arriving before its parent has nowhere to attach.
    @Test func everyFolderOnTheWayDownOpens() {
        #expect(ancestors("/w/a/b/c.swift", under: "/w") == ["/w/a", "/w/a/b"])
    }

    /// The thing being revealed is never opened itself. For a file that would
    /// be meaningless, and for a folder it would show the reader inside
    /// something they only asked to see.
    @Test func theRevealedPathItselfNeverOpens() {
        #expect(!ancestors("/w/a/b", under: "/w").contains("/w/a/b"))
    }

    /// A file sitting directly in the root needs nothing opened: the root's
    /// own children are always drawn.
    @Test func aFileInTheRootNeedsNoFolders() {
        #expect(ancestors("/w/c.swift", under: "/w").isEmpty)
    }

    @Test func theRootItselfOpensNothing() {
        #expect(ancestors("/w", under: "/w").isEmpty)
    }

    // MARK: Paths that aren't in the tree

    /// A file open in the editor need not be in the workspace at all — the
    /// answer is to expand nothing, not to guess at a shared ancestor and
    /// open half the disk on the way to it.
    @Test func aPathOutsideTheRootOpensNothing() {
        #expect(ancestors("/elsewhere/c.swift", under: "/w").isEmpty)
    }

    /// The boundary is a path component, not a string prefix. `/w/application`
    /// starts with `/w/app` and has nothing to do with it; treating it as
    /// inside would expand folders belonging to a different tree.
    @Test func aSiblingSharingAPrefixIsOutside() {
        #expect(ancestors("/w/application/c.swift", under: "/w/app").isEmpty)
    }

    @Test func aRootThatIsNotAPathOpensNothing() {
        #expect(ancestors("/w/a/c.swift", under: "").isEmpty)
    }

    // MARK: Shapes of the same path

    /// A root arrives from a URL and a path from a tab, and only one of them
    /// tends to carry a trailing slash. They have to mean the same tree.
    @Test func aTrailingSlashChangesNothing() {
        #expect(ancestors("/w/a/b/c.swift", under: "/w/") == ["/w/a", "/w/a/b"])
        #expect(ancestors("/w/a/b/", under: "/w") == ["/w/a"])
        #expect(ancestors("/w/", under: "/w").isEmpty)
    }

    /// A tree rooted at the disk is a legitimate, if unusual, workspace: the
    /// root is one slash long and every path is inside it.
    @Test func theFilesystemRootIsAnOrdinaryRoot() {
        #expect(ancestors("/a/b.txt", under: "/") == ["/a"])
        #expect(ancestors("/b.txt", under: "/").isEmpty)
    }
}

/// The same reveal against a real tree on disk: the folders actually open,
/// the row actually appears, and nothing else gets listed on the way.
@MainActor
struct FileExplorerRevealModelTests {
    /// Resolved through `realpath` for the reason `FileExplorerTests`
    /// documents: temp directories sit behind the `/var` → `/private/var`
    /// symlink, and `FileManager` hands back the resolved form.
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Listings run off the main actor, so every assertion about rows has to
    /// wait for the ones in flight. Bounded, so a directory that never
    /// answers fails the test instead of hanging the suite.
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

    private func makeTree(_ base: URL) throws -> URL {
        let deep = base.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("a/other", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("sibling", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: base.appendingPathComponent("a/other/hidden-away.txt"))
        try Data().write(to: base.appendingPathComponent("sibling/elsewhere.txt"))

        let file = deep.appendingPathComponent("c.txt")
        try Data().write(to: file)
        return file
    }

    /// The whole point: the row for the open file has to exist before it can
    /// be highlighted or scrolled to, and inside a collapsed folder it is
    /// never built at all.
    @Test func revealingAFileOpensTheFoldersItLivesIn() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeTree(base)

        let model = await rooted(at: base)
        #expect(!model.rows.contains { $0.id == file.path }, "it starts out of reach")

        model.expandAncestors(of: file.path)
        await settle(model)

        #expect(model.expanded.contains(base.appendingPathComponent("a").path))
        #expect(model.expanded.contains(base.appendingPathComponent("a/b").path))
        #expect(model.rows.contains { $0.id == file.path })
    }

    /// A reveal walks one branch. Opening the folders around it — a sibling
    /// of the root, a sibling of an ancestor — would list directories nobody
    /// asked about, which in a large repository is the difference between a
    /// handful of listings and thousands.
    @Test func nothingOffThePathIsListed() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeTree(base)

        let model = await rooted(at: base)
        model.expandAncestors(of: file.path)
        await settle(model)

        #expect(model.expanded == [
            base.appendingPathComponent("a").path,
            base.appendingPathComponent("a/b").path,
        ])
        #expect(!model.rows.contains { $0.node.name == "hidden-away.txt" })
        #expect(!model.rows.contains { $0.node.name == "elsewhere.txt" })
    }

    /// The file is not a folder. Adding it to the expanded set would leave a
    /// path in there that can never be collapsed from the tree, and would
    /// survive into the persisted expansion.
    @Test func theFileItselfIsNeverExpanded() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeTree(base)

        let model = await rooted(at: base)
        model.expandAncestors(of: file.path)
        await settle(model)

        #expect(!model.expanded.contains(file.path))
    }

    /// An editor tab can hold a file from anywhere — a dotfile in the home
    /// directory, a dependency's source. The tree it isn't in must not move.
    @Test func aFileOutsideTheTreeLeavesItAlone() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeTree(base)

        let model = await rooted(at: base)
        let before = model.rows.map(\.id)

        model.expandAncestors(of: "/somewhere/else/entirely.txt")
        await settle(model)

        #expect(model.expanded.isEmpty)
        #expect(model.rows.map(\.id) == before)
    }

    /// Revealing what is already revealed has to be free — the reveal fires
    /// on every switch between open files, and most of those are files the
    /// reader clicked in the tree a moment ago.
    @Test func revealingAFileAlreadyOnScreenChangesNothing() async throws {
        let base = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeTree(base)

        let model = await rooted(at: base)
        model.expandAncestors(of: file.path)
        await settle(model)

        let expanded = model.expanded
        let rows = model.rows.map(\.id)

        model.expandAncestors(of: file.path)
        await settle(model)

        #expect(model.expanded == expanded)
        #expect(model.rows.map(\.id) == rows)
    }
}

import Foundation
@testable import Ghostty
import Testing

/// Renaming, moving or deleting a *folder* while files inside it are open.
///
/// The bug: both handlers looked the path up as an exact document key, and a
/// folder is never a document key — so the whole thing was a silent no-op.
/// The tabs kept paths that no longer existed, each still watching a file at
/// its old location and still saving to it, and the language server never
/// heard the documents close. Renaming a folder is an ordinary thing to do
/// with two files from it open, which is what made this worth a suite.
@MainActor
struct EditorFolderRepathTests {
    /// Resolved through `realpath` for the same reason `FileExplorerTests`
    /// does it: temp directories sit behind the `/var` → `/private/var`
    /// symlink, and the paths that come back from `FileManager` are the
    /// resolved ones, so constructed expectations would never match.
    private func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func openPaths(_ center: EditorCenter) -> [String] {
        center.tabs.tabs.map(\.path)
    }

    @discardableResult
    private func makeFile(_ directory: URL, _ name: String, _ contents: String = "let a = 1") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Rename and move

    @Test func renamingAFolderMovesEveryTabInsideIt() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("src", isDirectory: true)
        let first = try makeFile(source, "a.ts")
        let second = try makeFile(source, "b.ts")

        let center = EditorCenter()
        #expect(center.open(first))
        #expect(center.open(second))

        let destination = base.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)
        center.repath(from: source.path, to: destination.path)

        #expect(center.documents[first.path] == nil)
        #expect(center.documents[second.path] == nil)
        #expect(center.documents[destination.appendingPathComponent("a.ts").path] != nil)
        #expect(center.documents[destination.appendingPathComponent("b.ts").path] != nil)
        #expect(openPaths(center).contains(destination.appendingPathComponent("a.ts").path))
        #expect(openPaths(center).contains(destination.appendingPathComponent("b.ts").path))
    }

    @Test func aNestedFileKeepsItsPlaceInTheMovedTree() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("src", isDirectory: true)
        let deep = try makeFile(source.appendingPathComponent("ui/parts", isDirectory: true), "Row.ts")

        let center = EditorCenter()
        #expect(center.open(deep))

        let destination = base.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)
        center.repath(from: source.path, to: destination.path)

        #expect(center.documents[destination.appendingPathComponent("ui/parts/Row.ts").path] != nil)
    }

    /// The unsaved buffer is the reason this can't just close and reopen the
    /// tabs: a folder rename must not be a way to lose work.
    @Test func unsavedEditsTravelWithTheFolder() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("src", isDirectory: true)
        let file = try makeFile(source, "a.ts")

        let center = EditorCenter()
        #expect(center.open(file))
        center.documents[file.path]?.edited("let a = 2")

        let destination = base.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)
        center.repath(from: source.path, to: destination.path)

        let moved = center.documents[destination.appendingPathComponent("a.ts").path]
        #expect(moved?.isDirty == true)
        #expect(moved?.currentText == "let a = 2")
    }

    /// Prefix matching has to stop at a path separator. "src2" starts with
    /// "src" and is a different folder entirely.
    @Test func aSiblingSharingAPrefixIsLeftAlone() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("src", isDirectory: true)
        try makeFile(source, "a.ts")
        let sibling = try makeFile(base.appendingPathComponent("src2", isDirectory: true), "b.ts")

        let center = EditorCenter()
        #expect(center.open(source.appendingPathComponent("a.ts")))
        #expect(center.open(sibling))

        let destination = base.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)
        center.repath(from: source.path, to: destination.path)

        #expect(center.documents[sibling.path] != nil, "src2 is not inside src")
    }

    @Test func aFileRenameStillMovesItsOwnTab() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let file = try makeFile(base, "old.ts")
        let center = EditorCenter()
        #expect(center.open(file))

        let renamed = base.appendingPathComponent("new.ts")
        try FileManager.default.moveItem(at: file, to: renamed)
        center.repath(from: file.path, to: renamed.path)

        #expect(center.documents[file.path] == nil)
        #expect(center.documents[renamed.path] != nil)
    }

    @Test func repathingSomethingWithNothingOpenInsideItDoesNothing() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let file = try makeFile(base, "a.ts")
        let center = EditorCenter()
        #expect(center.open(file))

        center.repath(from: base.appendingPathComponent("elsewhere").path,
                      to: base.appendingPathComponent("moved").path)

        #expect(center.documents[file.path] != nil)
        #expect(center.documents.count == 1)
    }

    // MARK: Delete

    @Test func deletingAFolderClosesEveryTabInsideIt() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("src", isDirectory: true)
        let first = try makeFile(source, "a.ts")
        let second = try makeFile(source.appendingPathComponent("deep", isDirectory: true), "b.ts")
        let outside = try makeFile(base, "keep.ts")

        let center = EditorCenter()
        #expect(center.open(first))
        #expect(center.open(second))
        #expect(center.open(outside))

        center.didDelete(path: source.path)

        #expect(center.documents[first.path] == nil)
        #expect(center.documents[second.path] == nil)
        #expect(center.documents[outside.path] != nil, "a file outside the folder stays open")
        #expect(!openPaths(center).contains(first.path))
        #expect(!openPaths(center).contains(second.path))
    }

    @Test func deletingAFileClosesOnlyThatFile() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try makeFile(base, "a.ts")
        let second = try makeFile(base, "b.ts")

        let center = EditorCenter()
        #expect(center.open(first))
        #expect(center.open(second))

        center.didDelete(path: first.path)

        #expect(center.documents[first.path] == nil)
        #expect(center.documents[second.path] != nil)
    }

    @Test func deletingSomethingThatWasNeverOpenIsHarmless() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let file = try makeFile(base, "a.ts")
        let center = EditorCenter()
        #expect(center.open(file))

        center.didDelete(path: base.appendingPathComponent("never-opened").path)

        #expect(center.documents.count == 1)
    }
}

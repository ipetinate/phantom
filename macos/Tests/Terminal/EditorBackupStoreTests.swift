import Foundation
import Testing

@testable import Ghostty

/// The unsaved buffer that survives closing the file and quitting the app.
///
/// The promise is absolute in one direction: this may lose a preference, but
/// it may never lose text somebody typed. So the tests that matter here are
/// the ones where something has gone wrong — the file moved, the record is
/// damaged, the app never got to close the tab — and the question is always
/// whether the writing survived.
@MainActor
@Suite(.serialized)
struct EditorBackupStoreTests {
    private func withStore(_ body: () throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString)")
        EditorStateFolder.override = directory
        defer {
            EditorStateFolder.override = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try body()
    }

    // MARK: The round trip

    @Test func anUnsavedBufferComesBack() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/a.txt", text: "typed", diskText: "saved")

            let restored = try #require(
                EditorBackupStore.load(path: "/tmp/a.txt", diskText: "saved"))
            #expect(restored.text == "typed")
            #expect(!restored.conflictsWithDisk)
        }
    }

    /// The case the whole thing exists to get right. The file changed while
    /// the app was closed, and the reader's own writing must still come back.
    @Test func aChangedFileStillReturnsTheWriting() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/b.txt", text: "my work", diskText: "before")

            let restored = try #require(
                EditorBackupStore.load(path: "/tmp/b.txt", diskText: "somebody else's"))
            #expect(restored.text == "my work", "the buffer is never discarded")
            #expect(restored.conflictsWithDisk, "but the reader has to be told")
        }
    }

    @Test func aBufferThatMatchesTheFileIsNotKept() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/c.txt", text: "same", diskText: "same")

            #expect(!EditorBackupStore.hasBackup(path: "/tmp/c.txt"))
        }
    }

    /// Typing back to what the file already holds has to remove the record,
    /// or a stale buffer would be restored over a file that matches it.
    @Test func editingBackToTheSavedTextClearsIt() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/d.txt", text: "typed", diskText: "saved")
            #expect(EditorBackupStore.hasBackup(path: "/tmp/d.txt"))

            EditorBackupStore.save(path: "/tmp/d.txt", text: "saved", diskText: "saved")
            #expect(!EditorBackupStore.hasBackup(path: "/tmp/d.txt"))
        }
    }

    /// Somebody saved the same text from elsewhere while the app was closed.
    /// There is nothing unsaved left, so there is nothing to put back.
    @Test func aBufferTheFileCaughtUpWithIsDropped() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/e.txt", text: "typed", diskText: "saved")

            #expect(EditorBackupStore.load(path: "/tmp/e.txt", diskText: "typed") == nil)
            #expect(!EditorBackupStore.hasBackup(path: "/tmp/e.txt"))
        }
    }

    @Test func aBufferOverTheCapIsNotKept() throws {
        try withStore {
            let huge = String(repeating: "x", count: EditorBackupStore.maximumBytes + 1)
            EditorBackupStore.save(path: "/tmp/f.txt", text: huge, diskText: "")

            #expect(!EditorBackupStore.hasBackup(path: "/tmp/f.txt"))
        }
    }

    @Test func aDamagedRecordIsNotAnError() throws {
        try withStore {
            let url = try #require(EditorStateFolder.fileURL(for: "/tmp/g.txt", in: EditorBackupStore.folder))
            try Data("{\"version\":1,\"text\":".utf8).write(to: url)

            #expect(EditorBackupStore.load(path: "/tmp/g.txt", diskText: "x") == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func aRenamedFileKeepsItsBuffer() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/old.txt", text: "typed", diskText: "saved")
            EditorBackupStore.repath(from: "/tmp/old.txt", to: "/tmp/new.txt")

            #expect(!EditorBackupStore.hasBackup(path: "/tmp/old.txt"))
            let restored = try #require(
                EditorBackupStore.load(path: "/tmp/new.txt", diskText: "saved"))
            #expect(restored.text == "typed")
        }
    }

    @Test func twoFilesDoNotShareARecord() throws {
        try withStore {
            EditorBackupStore.save(path: "/tmp/one.txt", text: "one", diskText: "base")
            EditorBackupStore.save(path: "/tmp/two.txt", text: "two", diskText: "base")

            #expect(EditorBackupStore.load(path: "/tmp/one.txt", diskText: "base")?.text == "one")
            #expect(EditorBackupStore.load(path: "/tmp/two.txt", diskText: "base")?.text == "two")
        }
    }

    @Test func theFileNameDoesNotContainThePath() throws {
        try withStore {
            let url = try #require(EditorStateFolder.fileURL(
                for: "/Users/someone/Clients/acme/secret.txt", in: EditorBackupStore.folder))

            #expect(!url.lastPathComponent.contains("acme"))
            #expect(!url.lastPathComponent.contains("secret"))
        }
    }

    /// The suite must not write into the reader's own unsaved work.
    @Test func aTestWithNoStoreOfItsOwnWritesNothing() {
        EditorStateFolder.override = nil

        EditorBackupStore.save(path: "/tmp/leak.txt", text: "typed", diskText: "saved")

        #expect(!EditorBackupStore.hasBackup(path: "/tmp/leak.txt"))
    }
}

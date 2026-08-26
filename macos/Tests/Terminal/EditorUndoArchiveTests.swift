import Foundation
import Testing

@testable import Ghostty

/// The undo history that survives quitting.
///
/// The promise being tested is narrow and absolute: a history comes back only
/// when the file is byte-for-byte what it was, and otherwise comes back empty.
/// Everything else here is about making sure the empty case is reached rather
/// than a wrong history being applied to somebody's file.
@MainActor
@Suite(.serialized)
struct EditorUndoArchiveTests {
    /// Stands in for the text view, the way the timeline suites do it.
    final class TimelineBuffer: CodeUndoTarget {
        let text = NSMutableString()
        init(_ initial: String) { text.setString(initial) }
        var string: String { text as String }

        func applyUndoStep(_ step: CodeUndoStep, undoing: Bool) {
            let range = undoing ? step.rangeAfter : step.range
            guard NSMaxRange(range) <= text.length else { return }
            text.replaceCharacters(in: range, with: undoing ? step.removed : step.inserted)
        }
    }

    /// Each test gets its own folder. The test bundle is hosted inside the app
    /// and shares its bundle identifier, so without this a run would write
    /// into — and prune — the real undo history on the machine.
    private func withArchive(_ body: (String) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-archive-\(UUID().uuidString)")
        EditorUndoArchive.directoryOverride = directory
        defer {
            EditorUndoArchive.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.path)
    }

    private func step(_ inserted: String, at location: Int = 0) -> CodeUndoStep {
        CodeUndoStep(
            range: NSRange(location: location, length: 0),
            removed: "",
            inserted: inserted,
            selectionBefore: NSRange(location: location, length: 0),
            selectionAfter: NSRange(location: location + inserted.count, length: 0),
            name: "Typing")
    }

    // MARK: The round trip

    @Test func aHistoryComesBackWhenTheTextIsUnchanged() throws {
        try withArchive { _ in
            let text = "hello world"
            let steps = [step("hello "), step("world", at: 6)]

            EditorUndoArchive.save(
                path: "/tmp/a.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: text),
                steps: steps)

            let loaded = try #require(
                EditorUndoArchive.load(path: "/tmp/a.txt", matching: text))
            #expect(loaded == steps)
        }
    }

    /// Every field has to survive, not just the text. A step whose offsets
    /// decode wrong is the corruption case: it applies somewhere else in the
    /// file and the reader finds out on the next save.
    @Test func everyFieldSurvivesTheRoundTrip() throws {
        try withArchive { _ in
            let original = CodeUndoStep(
                range: NSRange(location: 17, length: 4),
                removed: "old\n\ttext with \"quotes\" and emoji 🇧🇷",
                inserted: "new",
                selectionBefore: NSRange(location: 17, length: 4),
                selectionAfter: NSRange(location: 20, length: 0),
                name: "Formatting")

            let data = try JSONEncoder().encode([original])
            let back = try JSONDecoder().decode([CodeUndoStep].self, from: data)

            #expect(back.first?.range == original.range)
            #expect(back.first?.removed == original.removed)
            #expect(back.first?.inserted == original.inserted)
            #expect(back.first?.selectionBefore == original.selectionBefore)
            #expect(back.first?.selectionAfter == original.selectionAfter)
            #expect(back.first?.name == original.name)
        }
    }

    // MARK: The refusals

    /// The one that matters. A file changed behind the app's back — a
    /// `git checkout`, another editor — must not get its old history applied
    /// to it.
    @Test func aChangedFileGetsNoHistory() throws {
        try withArchive { _ in
            EditorUndoArchive.save(
                path: "/tmp/b.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "before"),
                steps: [step("before")])

            #expect(EditorUndoArchive.load(path: "/tmp/b.txt", matching: "after") == nil)
        }
    }

    /// And having been turned down once, the record is gone: the text will
    /// never hash back to what it was.
    @Test func aRefusedRecordIsDeleted() throws {
        try withArchive { _ in
            EditorUndoArchive.save(
                path: "/tmp/c.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "before"),
                steps: [step("before")])
            _ = EditorUndoArchive.load(path: "/tmp/c.txt", matching: "after")

            let url = try #require(EditorUndoArchive.url(for: "/tmp/c.txt"))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func aTruncatedFileIsNotAnError() throws {
        try withArchive { _ in
            let url = try #require(EditorUndoArchive.url(for: "/tmp/d.txt"))
            try Data("{\"version\":2,\"steps\":[".utf8).write(to: url)

            #expect(EditorUndoArchive.load(path: "/tmp/d.txt", matching: "anything") == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func aRecordFromAnotherFormatIsDropped() throws {
        try withArchive { _ in
            let url = try #require(EditorUndoArchive.url(for: "/tmp/e.txt"))
            let stale = """
                {"version":1,"path":"/tmp/e.txt","fingerprint":"","steps":[],\
                "written":0}
                """
            try Data(stale.utf8).write(to: url)

            #expect(EditorUndoArchive.load(path: "/tmp/e.txt", matching: "x") == nil)
        }
    }

    @Test func anEmptyHistoryLeavesNothingBehind() throws {
        try withArchive { _ in
            EditorUndoArchive.save(
                path: "/tmp/f.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "x"),
                steps: [step("x")])
            EditorUndoArchive.save(
                path: "/tmp/f.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "x"),
                steps: [])

            let url = try #require(EditorUndoArchive.url(for: "/tmp/f.txt"))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Two paths must not share a record. The filename is a hash and a
    /// collision would hand one file another file's text.
    @Test func recordsAreKeptApartByPath() throws {
        try withArchive { _ in
            EditorUndoArchive.save(
                path: "/tmp/one.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "same"),
                steps: [step("one")])
            EditorUndoArchive.save(
                path: "/tmp/two.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "same"),
                steps: [step("two")])

            let one = try #require(EditorUndoArchive.load(path: "/tmp/one.txt", matching: "same"))
            let two = try #require(EditorUndoArchive.load(path: "/tmp/two.txt", matching: "same"))
            #expect(one.first?.inserted == "one")
            #expect(two.first?.inserted == "two")
        }
    }

    /// The folder listing must not read as a list of what the reader works on.
    @Test func theFileNameDoesNotContainThePath() throws {
        try withArchive { _ in
            let url = try #require(
                EditorUndoArchive.url(for: "/Users/someone/Clients/acme/secret.txt"))

            #expect(!url.lastPathComponent.contains("acme"))
            #expect(!url.lastPathComponent.contains("secret"))
            #expect(url.lastPathComponent.hasSuffix(".json"))
        }
    }

    // MARK: Through the center, which is how the app reaches it

    /// The whole promise in one test: type, close the tab, quit, launch again,
    /// open the same file, undo.
    @Test func aHistorySurvivesAQuitAndRelaunch() throws {
        try withArchive { _ in
            EditorUndoCenter.shared.forgetEverything()
            defer { EditorUndoCenter.shared.forgetEverything() }

            let path = "/tmp/relaunch-\(UUID().uuidString).txt"
            let timeline = EditorUndoCenter.shared.attach(path: path, text: "")
            let buffer = TimelineBuffer("")
            timeline.target = buffer

            let typed = step("hello")
            buffer.text.replaceCharacters(in: typed.range, with: typed.inserted)
            timeline.record(typed, at: 0)

            /// Closing the tab is what writes the record.
            EditorUndoCenter.shared.detach(path: path, text: buffer.string)

            /// Quitting: everything in memory goes away, the disk does not.
            EditorUndoCenter.shared.forgetEverything()

            let reopened = EditorUndoCenter.shared.attach(path: path, text: "hello")
            let second = TimelineBuffer("hello")
            reopened.target = second

            #expect(reopened.canUndo)
            #expect(reopened.undo())
            #expect(second.string == "")
        }
    }

    /// The same relaunch, but the file changed while the app was closed. This
    /// is the case the feature must get wrong in the reader's favour.
    @Test func aFileChangedWhileClosedComesBackWithNoHistory() throws {
        try withArchive { _ in
            EditorUndoCenter.shared.forgetEverything()
            defer { EditorUndoCenter.shared.forgetEverything() }

            let path = "/tmp/checkout-\(UUID().uuidString).txt"
            let timeline = EditorUndoCenter.shared.attach(path: path, text: "")
            let buffer = TimelineBuffer("")
            timeline.target = buffer

            let typed = step("hello")
            buffer.text.replaceCharacters(in: typed.range, with: typed.inserted)
            timeline.record(typed, at: 0)
            EditorUndoCenter.shared.detach(path: path, text: buffer.string)
            EditorUndoCenter.shared.forgetEverything()

            /// A `git checkout` happened in the terminal next to the editor.
            let reopened = EditorUndoCenter.shared.attach(path: path, text: "something else")

            #expect(!reopened.canUndo)
        }
    }

    /// Quitting with the tab still open is the ordinary way to quit, and the
    /// one path where nothing ever calls `detach`.
    @Test func quittingWithTheFileOpenStillWritesTheHistory() throws {
        try withArchive { _ in
            EditorUndoCenter.shared.forgetEverything()
            defer { EditorUndoCenter.shared.forgetEverything() }

            let path = "/tmp/quit-\(UUID().uuidString).txt"
            let timeline = EditorUndoCenter.shared.attach(path: path, text: "")
            let buffer = TimelineBuffer("")
            timeline.target = buffer

            let typed = step("hello")
            buffer.text.replaceCharacters(in: typed.range, with: typed.inserted)
            timeline.record(typed, at: 0)

            EditorUndoCenter.shared.persistOpenFiles(texts: [path: buffer.string])
            EditorUndoCenter.shared.forgetEverything()

            let reopened = EditorUndoCenter.shared.attach(path: path, text: "hello")
            #expect(reopened.canUndo)
        }
    }

    /// A file whose history was thrown away must not have it handed back by
    /// the archive on the next open.
    @Test func invalidatingAFileAlsoClearsItsRecord() throws {
        try withArchive { _ in
            EditorUndoCenter.shared.forgetEverything()
            defer { EditorUndoCenter.shared.forgetEverything() }

            let path = "/tmp/invalid-\(UUID().uuidString).txt"
            let timeline = EditorUndoCenter.shared.attach(path: path, text: "")
            let buffer = TimelineBuffer("")
            timeline.target = buffer

            let typed = step("hello")
            buffer.text.replaceCharacters(in: typed.range, with: typed.inserted)
            timeline.record(typed, at: 0)
            EditorUndoCenter.shared.detach(path: path, text: buffer.string)

            EditorUndoCenter.shared.invalidate(path: path)
            EditorUndoCenter.shared.forgetEverything()

            let reopened = EditorUndoCenter.shared.attach(path: path, text: "hello")
            #expect(!reopened.canUndo)
        }
    }

    @Test func pruneRemovesOldRecords() throws {
        try withArchive { directory in
            EditorUndoArchive.save(
                path: "/tmp/g.txt",
                fingerprint: EditorUndoArchive.fingerprint(of: "x"),
                steps: [step("x")])

            let url = try #require(EditorUndoArchive.url(for: "/tmp/g.txt"))
            let old = Date().addingTimeInterval(-EditorUndoArchive.maximumAge - 60)
            try FileManager.default.setAttributes(
                [.modificationDate: old], ofItemAtPath: url.path)

            EditorUndoArchive.prune()

            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: directory))
        }
    }
}

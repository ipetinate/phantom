import AppKit
@testable import Ghostty
import Testing

/// The store that keeps a file's undo history after its tab has gone.
///
/// Two promises are being pinned, and they pull against each other. The
/// reader asked to close a file, come back to it and still be able to press
/// ⌘Z — so the history has to outlive the document. But a file that is not
/// open is a file the world can change, and undoing into somebody else's
/// commit and then saving over it is the one failure an editor may not
/// produce. So: it survives a close, and it does not survive the file
/// changing while it was closed.
@MainActor
@Suite(.serialized)
struct EditorUndoCenterTests {
    private final class Buffer: CodeUndoTarget {
        let text = NSMutableString()
        init(_ initial: String) { text.setString(initial) }
        var string: String { text as String }

        func applyUndoStep(_ step: CodeUndoStep, undoing: Bool) {
            let range = undoing ? step.rangeAfter : step.range
            guard NSMaxRange(range) <= text.length else { return }
            text.replaceCharacters(in: range, with: undoing ? step.removed : step.inserted)
        }
    }

    /// One typed character, recorded and registered.
    private func type(
        _ character: String,
        at location: Int,
        into timeline: CodeUndoTimeline,
        buffer: Buffer
    ) {
        buffer.text.insert(character, at: location)
        timeline.record(
            CodeUndoStep(
                range: NSRange(location: location, length: 0),
                removed: "",
                inserted: character,
                selectionBefore: NSRange(location: location, length: 0),
                selectionAfter: NSRange(location: location + 1, length: 0),
                name: "Typing"),
            at: 0)
        timeline.flush()
    }

    private func freshCenter() -> EditorUndoCenter {
        let center = EditorUndoCenter.shared
        center.forgetEverything()
        return center
    }

    // MARK: Surviving a close

    @Test func historySurvivesClosingAndReopeningTheFile() {
        let center = freshCenter()
        let path = "/tmp/phantom-undo/a.ts"

        let timeline = center.attach(path: path, text: "let a")
        let buffer = Buffer("let a")
        timeline.target = buffer
        type("!", at: 5, into: timeline, buffer: buffer)
        #expect(buffer.string == "let a!")

        /// Closing the tab: the buffer is remembered, the view is not.
        center.detach(path: path, text: buffer.string)
        #expect(center.hasHistory(forPath: path))

        /// Opening it again, with the file exactly as it was left.
        let reopened = center.attach(path: path, text: "let a!")
        #expect(reopened === timeline, "the same file gets the same history")

        let rebuilt = Buffer("let a!")
        reopened.target = rebuilt
        reopened.undo()
        #expect(rebuilt.string == "let a", "⌘Z works on a file that was closed and reopened")
    }

    // MARK: The dangerous case

    /// A `git checkout` in the terminal next to the editor, under a closed
    /// tab. Every step in the timeline describes text that is no longer in
    /// the file, so applying one would splice the old file into the new one —
    /// and the next ⌘S would write that over the checkout.
    @Test func aFileThatChangedWhileClosedComesBackWithNoHistory() {
        let center = freshCenter()
        let path = "/tmp/phantom-undo/b.ts"

        let timeline = center.attach(path: path, text: "on-main")
        let buffer = Buffer("on-main")
        timeline.target = buffer
        type("!", at: 7, into: timeline, buffer: buffer)
        center.detach(path: path, text: buffer.string)
        #expect(center.hasHistory(forPath: path))

        let reopened = center.attach(path: path, text: "on-another-branch")
        #expect(reopened.canUndo == false, "the history describes a file that is gone")
        #expect(center.hasHistory(forPath: path) == false)
    }

    /// The check runs on the text the file was opened with, so an unchanged
    /// file keeps everything. Stated separately because a rule that clears
    /// too eagerly is indistinguishable, from the reader's side, from the bug
    /// this whole feature was written to fix.
    @Test func anUnchangedFileKeepsEverything() {
        let center = freshCenter()
        let path = "/tmp/phantom-undo/c.ts"

        let timeline = center.attach(path: path, text: "same")
        let buffer = Buffer("same")
        timeline.target = buffer
        type("r", at: 4, into: timeline, buffer: buffer)
        center.detach(path: path, text: "samer")

        #expect(center.attach(path: path, text: "samer").canUndo)
    }

    /// A file that is open has no fingerprint to fail, so opening it twice —
    /// clicking it again in the Git panel, say — must not throw away what is
    /// on its stack.
    @Test func reopeningAnAlreadyOpenFileKeepsItsHistory() {
        let center = freshCenter()
        let path = "/tmp/phantom-undo/d.ts"

        let timeline = center.attach(path: path, text: "x")
        let buffer = Buffer("x")
        timeline.target = buffer
        type("y", at: 1, into: timeline, buffer: buffer)

        /// The text the second open reads is the one on *disk*, which is not
        /// what the buffer holds — the reader has unsaved edits. A check here
        /// would fire on every such open.
        #expect(center.attach(path: path, text: "x").canUndo)
    }

    // MARK: Following the file

    @Test func renamingAFileCarriesItsHistory() {
        let center = freshCenter()
        let old = "/tmp/phantom-undo/old.ts"
        let new = "/tmp/phantom-undo/new.ts"

        let timeline = center.attach(path: old, text: "v")
        let buffer = Buffer("v")
        timeline.target = buffer
        type("2", at: 1, into: timeline, buffer: buffer)

        center.repath(from: old, to: new)
        #expect(center.hasHistory(forPath: new))
        #expect(center.hasHistory(forPath: old) == false)
        #expect(center.timeline(forPath: new) === timeline)
    }

    @Test func invalidatingThrowsAFilesHistoryAway() {
        let center = freshCenter()
        let path = "/tmp/phantom-undo/e.ts"
        let timeline = center.attach(path: path, text: "q")
        let buffer = Buffer("q")
        timeline.target = buffer
        type("r", at: 1, into: timeline, buffer: buffer)

        center.invalidate(path: path)
        #expect(center.hasHistory(forPath: path) == false)
    }

    // MARK: The bound

    /// The map is bounded, and open files are not what it drops: a live
    /// buffer recording into a timeline nothing will hand back again is a
    /// history that silently stops existing while it is being written.
    @Test func onlyClosedFilesAreEvicted() {
        let center = freshCenter()
        let open = "/tmp/phantom-undo/open.ts"
        let kept = center.attach(path: open, text: "kept")

        for index in 0...(EditorUndoCenter.maximumFiles + 5) {
            let path = "/tmp/phantom-undo/closed-\(index).ts"
            center.attach(path: path, text: "x")
            center.detach(path: path, text: "x")
        }

        #expect(center.timeline(forPath: open) === kept)
        center.forgetEverything()
    }
}

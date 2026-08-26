import AppKit
@testable import Ghostty
import Testing

/// The record the timeline keeps of its own stack.
///
/// `UndoManager` does not let anybody read its stack back, so the timeline
/// keeps a parallel array to have something to write to disk. Two accounts of
/// one stack is exactly the shape that drifts, and drift here is not a lost
/// undo — it is a step that will be replayed against text it does not match.
/// So the property pinned below is the strong one: replaying the mirror from
/// the original text has to reproduce the buffer, after any sequence of edits.
@MainActor
@Suite(.serialized)
struct CodeUndoTimelineMirrorTests {
    private final class Buffer: CodeUndoTarget {
        let text = NSMutableString()
        var selection = NSRange(location: 0, length: 0)

        init(_ initial: String = "") { text.setString(initial) }

        func applyUndoStep(_ step: CodeUndoStep, undoing: Bool) {
            let range = undoing ? step.rangeAfter : step.range
            let replacement = undoing ? step.removed : step.inserted
            guard NSMaxRange(range) <= text.length else { return }
            text.replaceCharacters(in: range, with: replacement)
            selection = undoing ? step.selectionBefore : step.selectionAfter
        }

        var string: String { text as String }
    }

    private func insertion(_ inserted: String, at location: Int) -> CodeUndoStep {
        CodeUndoStep(
            range: NSRange(location: location, length: 0),
            removed: "",
            inserted: inserted,
            selectionBefore: NSRange(location: location, length: 0),
            selectionAfter: NSRange(location: location + (inserted as NSString).length, length: 0),
            name: "Typing")
    }

    /// Applies steps to a fresh buffer the way the editor would have.
    private func replay(_ steps: [CodeUndoStep], from initial: String) -> String {
        let buffer = Buffer(initial)
        for step in steps { buffer.applyUndoStep(step, undoing: false) }
        return buffer.string
    }

    /// Records `inserted` into both the timeline and the buffer, as an edit
    /// the reader made. Times are spaced past the coalescing window so each
    /// call is its own step.
    private func type(
        _ inserted: String, at location: Int,
        into timeline: CodeUndoTimeline, buffer: Buffer, time: TimeInterval
    ) {
        let step = insertion(inserted, at: location)
        buffer.text.replaceCharacters(in: step.range, with: inserted)
        timeline.record(step, at: time)
    }

    // MARK: The invariant

    @Test func replayingTheMirrorReproducesTheBuffer() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        type("alpha", at: 0, into: timeline, buffer: buffer, time: 0)
        type(" beta", at: 5, into: timeline, buffer: buffer, time: 10)
        type(" gamma", at: 10, into: timeline, buffer: buffer, time: 20)
        timeline.flush()

        #expect(buffer.string == "alpha beta gamma")
        #expect(replay(timeline.steps, from: "") == buffer.string)
    }

    @Test func theMirrorFollowsAnUndo() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        type("one", at: 0, into: timeline, buffer: buffer, time: 0)
        type("two", at: 3, into: timeline, buffer: buffer, time: 10)
        timeline.flush()
        #expect(timeline.steps.count == 2)

        #expect(timeline.undo())

        #expect(buffer.string == "one")
        #expect(timeline.steps.count == 1)
        #expect(replay(timeline.steps, from: "") == buffer.string)
    }

    @Test func theMirrorFollowsARedo() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        type("one", at: 0, into: timeline, buffer: buffer, time: 0)
        type("two", at: 3, into: timeline, buffer: buffer, time: 10)
        timeline.flush()

        #expect(timeline.undo())
        #expect(timeline.redo())

        #expect(buffer.string == "onetwo")
        #expect(timeline.steps.count == 2)
        #expect(replay(timeline.steps, from: "") == buffer.string)
    }

    /// Undo, undo, then type: the redone branch is gone from `UndoManager`
    /// and must be gone from the mirror too, or the archive would carry steps
    /// that no longer describe the file.
    @Test func typingAfterAnUndoDropsTheAbandonedBranch() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        type("one", at: 0, into: timeline, buffer: buffer, time: 0)
        type("two", at: 3, into: timeline, buffer: buffer, time: 10)
        timeline.flush()
        #expect(timeline.undo())

        type("three", at: 3, into: timeline, buffer: buffer, time: 20)
        timeline.flush()

        #expect(buffer.string == "onethree")
        #expect(replay(timeline.steps, from: "") == buffer.string)
    }

    @Test func clearEmptiesTheMirror() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        type("one", at: 0, into: timeline, buffer: buffer, time: 0)
        timeline.flush()
        timeline.clear()

        #expect(timeline.steps.isEmpty)
        #expect(!timeline.canUndo)
    }

    @Test func theMirrorStaysWithinTheStepBudget() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        for index in 0..<(CodeUndoTimeline.maximumSteps + 20) {
            type("x", at: index, into: timeline, buffer: buffer, time: Double(index) * 10)
        }
        timeline.flush()

        #expect(timeline.steps.count <= CodeUndoTimeline.maximumSteps)
    }

    // MARK: Coming back

    @Test func restoreRebuildsAWorkingUndoStack() {
        let first = Buffer()
        let recorded = CodeUndoTimeline()
        recorded.target = first
        type("hello", at: 0, into: recorded, buffer: first, time: 0)
        type(" world", at: 5, into: recorded, buffer: first, time: 10)
        recorded.flush()

        /// A new launch: same text, a timeline that has never seen it.
        let reopened = Buffer(first.string)
        let timeline = CodeUndoTimeline()
        timeline.target = reopened
        #expect(timeline.restore(recorded.steps))

        #expect(timeline.canUndo)
        #expect(!timeline.canRedo, "a restored history has nothing to redo yet")

        #expect(timeline.undo())
        #expect(reopened.string == "hello")
        #expect(timeline.undo())
        #expect(reopened.string == "")
    }

    /// Undo after a restore has to put redo back into play, or the reader can
    /// walk backwards past what they wanted and not return.
    @Test func redoWorksAfterUndoingARestoredStep() {
        let recorded = CodeUndoTimeline()
        let source = Buffer()
        recorded.target = source
        type("hello", at: 0, into: recorded, buffer: source, time: 0)
        recorded.flush()

        let buffer = Buffer("hello")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer
        timeline.restore(recorded.steps)

        #expect(timeline.undo())
        #expect(buffer.string == "")
        #expect(timeline.redo())
        #expect(buffer.string == "hello")
    }

    /// Restoring on top of a live history would interleave two accounts of the
    /// same file, and there is no order between them that means anything.
    @Test func restoreRefusesOverAnExistingHistory() {
        let buffer = Buffer()
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        type("typed", at: 0, into: timeline, buffer: buffer, time: 0)
        timeline.flush()

        #expect(!timeline.restore([insertion("saved", at: 0)]))
        #expect(timeline.steps.count == 1)
        #expect(timeline.steps.first?.inserted == "typed")
    }

    @Test func restoringNothingChangesNothing() {
        let buffer = Buffer("text")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        #expect(timeline.restore([]))
        #expect(!timeline.canUndo)
        #expect(buffer.string == "text")
    }

    /// The step names come back with the steps, because the Edit menu reads
    /// them out and "Undo" with no verb is how you find out this was rebuilt.
    @Test func restoredStepsKeepTheirNames() {
        let buffer = Buffer("formatted")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        var step = insertion("formatted", at: 0)
        step.name = "Formatting"
        timeline.restore([step])

        #expect(timeline.undoActionName == "Formatting")
    }
}

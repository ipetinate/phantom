import AppKit
@testable import Ghostty
import Testing

/// The file's undo history, driven without a window.
///
/// The point of the type is that it is not a view: a stack stored on a text
/// view dies when SwiftUI rebuilds the pane, which is the whole of "⌘Z stops
/// working when I change tabs". So it is exercised here the way the app uses
/// it and the way the app cannot be tested — buffer replaced underneath it,
/// bounds pushed past, a target dropped and a new one attached.
@MainActor
@Suite(.serialized)
struct CodeUndoTimelineTests {
    /// Stands in for the text view: it holds a string and applies steps to it.
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

    private func deletion(_ removed: String, at location: Int) -> CodeUndoStep {
        CodeUndoStep(
            range: NSRange(location: location, length: (removed as NSString).length),
            removed: removed,
            inserted: "",
            selectionBefore: NSRange(location: location + (removed as NSString).length, length: 0),
            selectionAfter: NSRange(location: location, length: 0),
            name: "Delete")
    }

    // MARK: Coalescing

    /// The reason coalescing exists: a run of typing has to come back as a
    /// run, not one character per ⌘Z.
    @Test func aRunOfTypingIsOneStep() {
        let buffer = Buffer("let a = ")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        for (index, character) in "123".enumerated() {
            buffer.text.append(String(character))
            timeline.record(insertion(String(character), at: 8 + index), at: Double(index) * 0.05)
        }
        #expect(buffer.string == "let a = 123")

        timeline.undo()
        #expect(buffer.string == "let a = ", "one undo takes back the whole run")
        #expect(timeline.canUndo == false)
    }

    /// A pause is a boundary. Without it a morning's typing is one step.
    @Test func aPauseEndsTheRun() {
        let buffer = Buffer("")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        buffer.text.append("ab")
        timeline.record(insertion("ab", at: 0), at: 0)
        buffer.text.append("cd")
        timeline.record(insertion("cd", at: 2), at: CodeUndoTimeline.coalescingWindow + 1)

        timeline.undo()
        #expect(buffer.string == "ab")
        timeline.undo()
        #expect(buffer.string == "")
    }

    /// Typing somewhere else is a different gesture even with no time between
    /// them — which is what a click in the middle of a word looks like.
    @Test func typingAtAnotherOffsetEndsTheRun() {
        let first = insertion("ab", at: 10)
        let elsewhere = insertion("cd", at: 40)
        #expect(first.continuing(elsewhere) == nil)
    }

    /// A newline ends a run either way, so undo gives back a line rather than
    /// a paragraph.
    @Test func aNewlineEndsTheRun() {
        let typed = insertion("ab", at: 0)
        let returned = insertion("\n", at: 2)
        #expect(typed.continuing(returned) == nil)
    }

    @Test func backspacesMergeIntoOneStep() {
        let buffer = Buffer("abcd")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        buffer.text.deleteCharacters(in: NSRange(location: 3, length: 1))
        timeline.record(deletion("d", at: 3), at: 0)
        buffer.text.deleteCharacters(in: NSRange(location: 2, length: 1))
        timeline.record(deletion("c", at: 2), at: 0.05)
        #expect(buffer.string == "ab")

        timeline.undo()
        #expect(buffer.string == "abcd", "the run comes back in the order it was taken")
    }

    @Test func forwardDeletesMergeIntoOneStep() {
        let buffer = Buffer("abcd")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        buffer.text.deleteCharacters(in: NSRange(location: 0, length: 1))
        timeline.record(deletion("a", at: 0), at: 0)
        buffer.text.deleteCharacters(in: NSRange(location: 0, length: 1))
        timeline.record(deletion("b", at: 0), at: 0.05)
        #expect(buffer.string == "cd")

        timeline.undo()
        #expect(buffer.string == "abcd")
    }

    /// Typing and deleting are different gestures however close together.
    @Test func anInsertionDoesNotJoinADeletion() {
        let deleted = deletion("x", at: 3)
        let typed = insertion("y", at: 3)
        #expect(deleted.continuing(typed) == nil)
    }

    // MARK: Ordering

    @Test func stepsComeBackNewestFirstAndGoForwardAgain() {
        let buffer = Buffer("")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        buffer.text.append("one")
        timeline.record(insertion("one", at: 0), at: 0)
        buffer.text.append("\n")
        timeline.record(insertion("\n", at: 3), at: 10)
        buffer.text.append("two")
        timeline.record(insertion("two", at: 4), at: 20)
        #expect(buffer.string == "one\ntwo")

        timeline.undo()
        #expect(buffer.string == "one\n")
        timeline.undo()
        #expect(buffer.string == "one")
        timeline.undo()
        #expect(buffer.string == "")
        #expect(timeline.canUndo == false)

        timeline.redo()
        #expect(buffer.string == "one")
        timeline.redo()
        timeline.redo()
        #expect(buffer.string == "one\ntwo")
        #expect(timeline.canRedo == false)
    }

    /// Undoing must not become the next thing to undo. It did, in the first
    /// version: the buffer change an undo produces flows back through the
    /// same hook that records typing.
    @Test func undoingDoesNotRecordItself() {
        let buffer = Buffer("")
        let timeline = CodeUndoTimeline()
        timeline.target = buffer

        buffer.text.append("x")
        timeline.record(insertion("x", at: 0), at: 0)
        timeline.flush()

        /// What the text view's hook does, guarded on exactly this flag.
        timeline.undo()
        #expect(timeline.isApplying == false)
        #expect(buffer.string == "")
        #expect(timeline.canUndo == false)
    }

    // MARK: Surviving the view

    /// The whole reason this type exists. The view that made the edit is
    /// gone; a new one is showing the same file; ⌘Z has to reach it.
    @Test func aStepSurvivesTheViewThatRecordedIt() {
        let timeline = CodeUndoTimeline()

        do {
            let first = Buffer("value")
            timeline.target = first
            first.text.append("s")
            timeline.record(insertion("s", at: 5), at: 0)
            timeline.flush()
        }

        /// A rebuilt pane arrives with the buffer as the host last knew it.
        let rebuilt = Buffer("values")
        timeline.target = rebuilt

        #expect(timeline.canUndo)
        timeline.undo()
        #expect(rebuilt.string == "value")
    }

    /// With nothing to put the text into, the step stays where it is rather
    /// than being consumed by a ⌘Z that could not do anything.
    @Test func undoDoesNothingWhileNoViewIsAttached() {
        let timeline = CodeUndoTimeline()
        let buffer = Buffer("ab")
        timeline.target = buffer
        buffer.text.append("c")
        timeline.record(insertion("c", at: 2), at: 0)
        timeline.flush()

        timeline.target = nil
        #expect(timeline.undo() == false)

        timeline.target = buffer
        #expect(timeline.undo())
        #expect(buffer.string == "ab")
    }

    // MARK: Bounds

    /// The step ceiling, and the reason it empties rather than skips: a
    /// timeline that quietly drops one step in the middle describes text
    /// either side of a gap, and undoing through it writes nonsense.
    @Test func aStepTooLargeToHoldEmptiesTheTimeline() {
        let timeline = CodeUndoTimeline()
        timeline.target = Buffer("")

        timeline.record(insertion("small", at: 0), at: 0)
        timeline.flush()
        #expect(timeline.canUndo)

        let huge = String(repeating: "x", count: CodeUndoTimeline.maximumStepBytes + 1)
        timeline.record(insertion(huge, at: 5), at: 10)
        timeline.flush()

        #expect(timeline.canUndo == false)
        #expect(timeline.byteCount == 0)
    }

    /// The byte ceiling drops the oldest steps rather than the newest, since
    /// the newest are the ones anybody is about to ask for.
    @Test func theOldestStepsGoWhenTheBudgetIsSpent() {
        let timeline = CodeUndoTimeline()
        timeline.target = Buffer("")

        let chunk = String(repeating: "y", count: 500 * 1024)
        for index in 0..<5 {
            timeline.record(insertion(chunk, at: index * 1_000_000), at: Double(index) * 10)
        }
        timeline.flush()

        #expect(timeline.byteCount <= CodeUndoTimeline.maximumBytes)
        #expect(timeline.byteCount > 0, "it trims, it does not empty")
    }

    @Test func theStepCeilingIsAHardOne() {
        let timeline = CodeUndoTimeline()
        let buffer = Buffer("")
        timeline.target = buffer

        for index in 0...(CodeUndoTimeline.maximumSteps + 20) {
            timeline.record(insertion("z", at: index * 100), at: Double(index) * 10)
        }
        timeline.flush()

        var taken = 0
        while timeline.undo() { taken += 1 }
        #expect(taken <= CodeUndoTimeline.maximumSteps)
        #expect(taken >= CodeUndoTimeline.maximumSteps - 1)
    }

    // MARK: The disk-changed rule

    /// A cleared timeline is the answer to "this file is not the file those
    /// steps describe" — see `EditorUndoCenter`.
    @Test func clearingLeavesNothingToUndoOrRedo() {
        let timeline = CodeUndoTimeline()
        let buffer = Buffer("")
        timeline.target = buffer
        buffer.text.append("a")
        timeline.record(insertion("a", at: 0), at: 0)
        timeline.flush()
        timeline.undo()

        timeline.clear()
        #expect(timeline.canUndo == false)
        #expect(timeline.canRedo == false)
        #expect(timeline.byteCount == 0)
    }

    /// A step that does not fit the buffer in front of it is refused by the
    /// text view rather than spliced at the wrong offset. Pinned on the step
    /// itself so the arithmetic the refusal reads is not guesswork.
    @Test func aStepKnowsExactlyWhatItReplaced() {
        let step = CodeUndoStep(
            range: NSRange(location: 4, length: 3),
            removed: "old",
            inserted: "longer",
            selectionBefore: NSRange(location: 4, length: 3),
            selectionAfter: NSRange(location: 10, length: 0),
            name: "Replace")

        #expect(step.rangeAfter == NSRange(location: 4, length: 6))
        #expect(step.byteCount == 9)
    }
}

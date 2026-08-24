import AppKit
@testable import Ghostty
import Testing

/// What happens to a buffer somebody is reading when the host replaces its
/// text.
///
/// Formatting used to rebuild the storage: `setAttributedString`, caret to
/// zero, scroll to the top. All three were reported as one complaint — *"it
/// moves the cursor to line 0 position 0 before any text"* — and the third
/// symptom was the quiet one: a storage replaced behind the text view's back
/// registers nothing on any undo stack, so ⌘Z after ⇧⌘F had nothing to take
/// back.
///
/// The coordinator is driven directly. Everything here is about what the
/// buffer and the selection do, and none of it needs a `NSViewRepresentable`
/// context, a layout pass or a window.
@MainActor
@Suite(.serialized)
struct CodeTextViewReplaceTests {
    private let theme = CodeTheme(
        foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
        background: NSColor(calibratedWhite: 0.1, alpha: 1),
        tokens: [:],
        lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
        currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
        currentLineBackground: nil
    )

    /// A text view in a scroll view, with a coordinator wired to it — the
    /// same three objects `makeNSView` builds, minus everything that only
    /// matters on screen.
    private func makeEditor() -> (CodeNSTextView, CodeTextView.Coordinator) {
        let textView = CodeNSTextView()
        textView.allowsUndo = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = textView

        let coordinator = CodeTextView.Coordinator(
            storage: CodeTextStorage(language: .javascript, theme: theme, configuration: .default),
            onEdit: { _ in })
        coordinator.textView = textView
        return (textView, coordinator)
    }

    private static let original = """
    const a = 1;
    const b   =   2;
    const c = 3;

    """

    private static let formatted = """
    const a = 1;
    const b = 2;
    const c = 3;

    """

    // MARK: The first load

    /// Opening a file is still allowed to start at the top, and must still
    /// leave the file's history alone — a ⌘Z whose first step empties the
    /// buffer is a trap, not an undo stack.
    @Test func loadingAFileStartsAtTheTopAndRecordsNothing() {
        let (textView, coordinator) = makeEditor()
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)

        #expect(textView.string == Self.original)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        #expect(textView.undoTimeline.canUndo == false)
    }

    // MARK: Formatting

    /// The complaint, stated as an assertion. The caret sat on `c` of the
    /// third line; after formatting it is still on `c` of the third line,
    /// even though that character moved four offsets earlier.
    @Test func formattingLeavesTheCaretOnTheSameText() {
        let (textView, coordinator) = makeEditor()
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)

        let before = (Self.original as NSString).range(of: "const c").location + 6
        textView.setSelectedRange(NSRange(location: before, length: 0))

        coordinator.applyIfNewRevision(text: Self.formatted, revision: 2)

        #expect(textView.string == Self.formatted)
        let after = textView.selectedRange().location
        let expected = (Self.formatted as NSString).range(of: "const c").location + 6
        #expect(after == expected)
        #expect(after != 0, "the caret used to be thrown to the start of the file")
    }

    /// A caret *before* the reformatted span does not move at all.
    @Test func aCaretAboveTheChangeDoesNotMove() {
        let (textView, coordinator) = makeEditor()
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        coordinator.applyIfNewRevision(text: Self.formatted, revision: 2)
        #expect(textView.selectedRange().location == 5)
    }

    /// The quiet half of the same bug. The formatter's edit has to travel the
    /// road a keystroke travels, or there is nothing to take back.
    @Test func formattingCanBeUndone() {
        let (textView, coordinator) = makeEditor()
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)
        coordinator.applyIfNewRevision(text: Self.formatted, revision: 2)

        #expect(textView.undoTimeline.canUndo, "⌘Z after ⇧⌘F had nothing to take back")
        textView.undo(nil)
        #expect(textView.string == Self.original)

        textView.redo(nil)
        #expect(textView.string == Self.formatted)
    }

    /// The Edit menu says what it is offering to take back, which is how the
    /// reader tells "undo my typing" from "undo that reformat".
    @Test func theMenuNamesTheFormat() {
        let (textView, coordinator) = makeEditor()
        coordinator.hostEditName = "Formatting"
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)
        coordinator.applyIfNewRevision(text: Self.formatted, revision: 2)

        let item = NSMenuItem(
            title: "Undo",
            action: #selector(CodeNSTextView.undo(_:)),
            keyEquivalent: "z")
        #expect(textView.validateMenuItem(item))
        #expect(item.title == "Undo Formatting")
    }

    /// Replacing the text with itself is not an edit, so it costs no step and
    /// moves nothing. This is the common case on a file that is already
    /// formatted, and a step for it would mean every ⌘S ate a ⌘Z.
    @Test func anIdenticalReplacementChangesNothing() {
        let (textView, coordinator) = makeEditor()
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        coordinator.applyIfNewRevision(text: Self.original, revision: 2)
        #expect(textView.selectedRange().location == 7)
        #expect(textView.undoTimeline.canUndo == false)
    }

    // MARK: Text that came off the disk

    /// A reload is the one replacement that must not be undoable. Undoing it
    /// would put the pre-checkout file back into the buffer, and the next ⌘S
    /// would write that over whatever the checkout left on disk.
    @Test func aReloadCannotBeUndoneAndTakesTheHistoryWithIt() {
        let (textView, coordinator) = makeEditor()
        coordinator.applyIfNewRevision(text: Self.original, revision: 1)

        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.undoTimeline.canUndo, "typing is on the stack")

        coordinator.hostEditIsUndoable = false
        coordinator.applyIfNewRevision(text: "a different branch\n", revision: 2)

        #expect(textView.string == "a different branch\n")
        #expect(textView.undoTimeline.canUndo == false)
        #expect(textView.undoTimeline.canRedo == false)
    }

    // MARK: Surviving the view

    /// The tab switch, in the small. SwiftUI destroys the pane and builds a
    /// new one; the file's timeline is handed to the new view, and ⌘Z there
    /// takes back what was typed in the old one.
    @Test func typingSurvivesTheViewBeingRebuilt() {
        let timeline = CodeUndoTimeline()

        do {
            let (first, coordinator) = makeEditor()
            first.undoTimeline = timeline
            coordinator.applyIfNewRevision(text: "let a = 1", revision: 1)
            first.insertText("2", replacementRange: NSRange(location: 9, length: 0))
            #expect(first.string == "let a = 12")
        }

        let (rebuilt, coordinator) = makeEditor()
        rebuilt.undoTimeline = timeline
        coordinator.applyIfNewRevision(text: "let a = 12", revision: 1)

        #expect(rebuilt.undoTimeline.canUndo)
        rebuilt.undo(nil)
        #expect(rebuilt.string == "let a = 1", "⌘Z has to survive changing tabs")
    }
}

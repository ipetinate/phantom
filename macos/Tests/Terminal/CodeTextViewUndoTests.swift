import AppKit
@testable import Ghostty
import Testing

/// ⌘Z inside the code editor.
///
/// `CodeNSTextView` overrides `undoManager` to keep the buffer's undo stack
/// separate from the window's — see the override for why. This checks the
/// override actually does what it is there for: a real keystroke followed by
/// a real undo has to reach the same manager.
@MainActor
struct CodeTextViewUndoTests {
    @Test func typingThenUndoingRemovesWhatWasTyped() {
        let textView = CodeNSTextView()
        textView.string = "let a = 1"

        textView.insertText("2", replacementRange: NSRange(location: 9, length: 0))
        #expect(textView.string == "let a = 12")

        textView.undoManager?.undo()
        #expect(textView.string == "let a = 1")
    }

    /// The override that makes the above work: without it, this view's own
    /// undo requests would be answered by whatever the window's first
    /// responder chain finds next — the app's own undo manager, in this app.
    @Test func theViewOwnsItsOwnUndoManagerRatherThanTheWindows() {
        let a = CodeNSTextView()
        let b = CodeNSTextView()
        #expect(a.undoManager !== b.undoManager)
    }
}

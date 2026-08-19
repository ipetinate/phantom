import AppKit
@testable import Ghostty
import Testing

/// ⌘Z reaching the editor through the path the menu actually uses.
///
/// The existing undo test calls `undo()` on the view directly, which proves
/// the view can undo and nothing about whether the menu can reach it. That
/// distinction is not academic: ⌘Z has been reported as doing nothing at all
/// while that test was green, because it exercised the piece and not the path.
///
/// The path is: menu item → `AppDelegate.undo(_:)` → the **first responder's**
/// undo manager. So what has to be true is that the first responder, when the
/// editor has focus, answers with the editor's own manager and not with the
/// window's — and the window's delegate deliberately answers with the
/// application's, which is what made this go wrong in the first place.
///
/// A window is created and never ordered front. Reaching `orderFront` in this
/// suite hangs it: the test host has no event loop.
@MainActor
struct EditorUndoPathTests {
    private func makeWindow(with view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        return window
    }

    /// The assumption the routing rests on, never previously asserted.
    @Test func theFocusedEditorAnswersWithItsOwnUndoManager() {
        let textView = CodeNSTextView()
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }

        #expect(window.makeFirstResponder(textView))
        #expect(window.firstResponder === textView)
        #expect(window.firstResponder?.undoManager === textView.undoManager)
    }

    /// Typing has to leave something on *that* manager, since it is the one
    /// the menu will ask. Registering on one and asking another is exactly
    /// how a menu item ends up enabled and inert.
    @Test func typingLeavesSomethingOnTheManagerTheMenuWillAsk() {
        let textView = CodeNSTextView()
        textView.allowsUndo = true
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }
        _ = window.makeFirstResponder(textView)

        textView.string = "let a = 1"
        textView.insertText("2", replacementRange: NSRange(location: 9, length: 0))

        let asked = window.firstResponder?.undoManager
        #expect(asked?.canUndo == true)

        asked?.undo()
        #expect(textView.string == "let a = 1")
    }

    /// Deleting an auto-closed pair with backspace used to write straight to
    /// the storage, which registers no undo step at all — so one backspace
    /// silently emptied the stack's usefulness in a file full of brackets.
    @Test func deletingAnAutoClosedPairCanBeUndone() {
        let textView = CodeNSTextView()
        textView.allowsUndo = true
        textView.closesBrackets = true
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }
        _ = window.makeFirstResponder(textView)

        /// The pair is placed rather than typed, and the caret put between
        /// its halves by hand. Typing it here would land the insertion and
        /// the deletion in **one** undo group — `NSUndoManager` groups by
        /// run-loop event, and a test does both in the same pass — so a
        /// single undo would revert both and the assertion would be about
        /// grouping rather than about registration.
        textView.string = "()"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.deleteBackward(nil)
        #expect(textView.string == "", "backspace between a pair deletes both halves")

        textView.undoManager?.undo()
        #expect(textView.string == "()", "backspace over a pair has to be undoable")
    }

    /// The link that was missing, and the one the report was about.
    ///
    /// Everything else here passed while ⌘Z did nothing, because every test
    /// asked the manager directly. The menu does not: it sends `undo:` down
    /// the responder chain, and until this view answered that selector the
    /// chain walked past it to the window — whose delegate hands back the
    /// application's manager — and validated the item against a stack that
    /// typing never touches. Grey item, and a grey item does not consume ⌘Z,
    /// so the key fell through to a beep.
    @Test func theFocusedEditorAnswersTheMenusUndoAction() {
        let textView = CodeNSTextView()
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }
        _ = window.makeFirstResponder(textView)

        #expect(window.firstResponder?.responds(to: #selector(CodeNSTextView.undo(_:))) == true)
        #expect(window.firstResponder?.responds(to: #selector(CodeNSTextView.redo(_:))) == true)
    }

    /// Validation and action have to agree, so this asks the exact question
    /// the menu asks — `validateMenuItem` with the menu's own selector —
    /// rather than reading `canUndo` and trusting that the item follows.
    @Test func theUndoItemEnablesOnceThereIsSomethingToUndo() {
        let textView = CodeNSTextView()
        textView.allowsUndo = true
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }
        _ = window.makeFirstResponder(textView)

        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(CodeNSTextView.undo(_:)),
            keyEquivalent: "z")

        #expect(textView.validateMenuItem(undoItem) == false, "nothing typed yet")
        #expect(undoItem.title == "Undo")

        textView.string = "let a = 1"
        textView.insertText("2", replacementRange: NSRange(location: 9, length: 0))

        #expect(textView.validateMenuItem(undoItem) == true)
        #expect(undoItem.title.hasPrefix("Undo"), "reads as Undo, or Undo plus what it holds")
    }

    /// Redo is the same path and breaks the same way, so it is pinned the
    /// same way rather than assumed to follow from undo.
    @Test func theRedoItemEnablesAfterAnUndo() {
        let textView = CodeNSTextView()
        textView.allowsUndo = true
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }
        _ = window.makeFirstResponder(textView)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(CodeNSTextView.redo(_:)),
            keyEquivalent: "Z")

        textView.string = "let a = 1"
        textView.insertText("2", replacementRange: NSRange(location: 9, length: 0))
        #expect(textView.validateMenuItem(redoItem) == false, "nothing undone yet")

        textView.undo(nil)
        #expect(textView.string == "let a = 1")

        #expect(textView.validateMenuItem(redoItem) == true)
        textView.redo(nil)
        #expect(textView.string == "let a = 12")
    }

    /// The rest of the Edit menu still belongs to `NSTextView`.
    ///
    /// Claiming two selectors means owning the answer for every other one
    /// too, and answering `true` by default there would light up Copy over an
    /// empty selection — which is the state a caret sitting in a file is
    /// always in.
    @Test func everyOtherMenuItemIsStillTheTextViewsToJudge() {
        let textView = CodeNSTextView()
        let window = makeWindow(with: textView)
        defer { window.contentView = nil }
        _ = window.makeFirstResponder(textView)
        textView.string = "let a = 1"

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(textView.validateMenuItem(copyItem) == false, "a caret has nothing to copy")

        textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(textView.validateMenuItem(copyItem) == true)
    }

    /// The window's own delegate answers with the application's manager, so a
    /// view that did *not* override `undoManager` would route window undo —
    /// "reopen the closed tab" — onto ⌘Z while editing. Pinned because the
    /// override is easy to read as redundant and delete.
    @Test func theEditorsManagerIsNotTheOneTheWindowWouldHandBack() {
        let textView = CodeNSTextView()
        let plain = NSView()
        let window = makeWindow(with: plain)
        defer { window.contentView = nil }

        #expect(textView.undoManager !== window.undoManager)
    }
}

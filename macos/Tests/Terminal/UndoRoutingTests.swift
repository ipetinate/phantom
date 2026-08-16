import AppKit
@testable import Ghostty
import Testing

/// Which undo manager ⌘Z reaches.
///
/// The defect these exist for lived entirely in the menu route, which is why
/// `CodeTextViewUndoTests` passed all the way through it: that suite calls
/// `undo()` on the view directly and never asks who the menu would have sent
/// it to. The menu sent it to the app-level manager every time — so Edit ▸
/// Undo was greyed out over a buffer full of unsaved typing, and ⌘Z reverted
/// nothing.
///
/// Nothing here builds a window, a menu or a responder chain. That is the
/// point of `UndoRouting` taking booleans: the rule is assertable on its own,
/// and it is the only part of this that could ever have had a test.
struct UndoRoutingTests {

    // MARK: Which Manager Acts

    /// The bug, stated as a rule: when the focused responder has something to
    /// undo, it is the one that undoes it. Typing in the editor cannot be
    /// answered by the manager that closes windows.
    @Test func theFocusedResponderWinsWhenItHasSomethingToUndo() {
        #expect(UndoRouting.target(responderCanAct: true, appCanAct: true)
            == .firstResponder)
    }

    /// And it wins whether or not the app-level manager has anything, because
    /// "who has focus" is the question, not "who has more".
    @Test func theFocusedResponderWinsEvenWhenTheAppHasNothing() {
        #expect(UndoRouting.target(responderCanAct: true, appCanAct: false)
            == .firstResponder)
    }

    /// The behaviour this must not break, and the only meaning ⌘Z had before
    /// the editor existed: with nothing focused that owns an undo stack — a
    /// terminal surface, or no key window at all after the last one closes —
    /// the app-level manager answers, and "undo close window" still works.
    @Test func theAppLevelManagerIsTheFallback() {
        #expect(UndoRouting.target(responderCanAct: false, appCanAct: true)
            == .application)
    }

    @Test func nothingToUndoAnywhereLeavesNobodyToAsk() {
        #expect(UndoRouting.target(responderCanAct: false, appCanAct: false)
            == .neither)
    }

    /// The menu item and the action are validated through this same call, so
    /// the four answers above are also the four states of the menu item. An
    /// enabled item that does nothing, or a greyed-out one over a stack that
    /// could have acted, is what disagreement between the two looks like.
    @Test func onlyTheEmptyCaseDisablesTheMenuItem() {
        let enabled: [UndoRouting.Target] = [.firstResponder, .application]
        for responder in [true, false] {
            for app in [true, false] {
                let target = UndoRouting.target(
                    responderCanAct: responder, appCanAct: app)
                #expect(enabled.contains(target) == (responder || app))
            }
        }
    }

    // MARK: What The Menu Item Says

    @Test func theTitleNamesWhatWouldBeUndone() {
        #expect(UndoRouting.menuTitle(verb: "Undo", actionName: "Typing")
            == "Undo Typing")
        #expect(UndoRouting.menuTitle(verb: "Redo", actionName: "Close Tab")
            == "Redo Close Tab")
    }

    /// An unnamed registration has an empty action name, and the old spelling
    /// pasted it on regardless — leaving "Undo " in the menu with a trailing
    /// space nobody put there.
    @Test func anUnnamedActionLeavesTheVerbAlone() {
        #expect(UndoRouting.menuTitle(verb: "Undo", actionName: "") == "Undo")
        #expect(UndoRouting.menuTitle(verb: "Redo", actionName: "") == "Redo")
    }

    // MARK: Against A Real Editor View

    /// The rule joined to the thing it is about. `CodeNSTextView` owns its own
    /// undo stack, and after a real keystroke that stack reports `canUndo` —
    /// which is the input that sends the menu to it rather than to the app.
    ///
    /// This is the assertion that would have failed before the fix, if the
    /// routing had existed to assert against.
    /// `allowsUndo` is set by the host in `makeNSView`, not by the view, so a
    /// bare one made here would be relying on whatever AppKit defaults to.
    /// Configured the way the running app configures it, so what this asserts
    /// is what the reader actually gets.
    @MainActor
    @Test func typingInTheEditorSendsTheMenuToTheEditor() {
        let textView = CodeNSTextView()
        textView.allowsUndo = true
        textView.string = "let a = 1"
        textView.insertText("2", replacementRange: NSRange(location: 9, length: 0))

        #expect(textView.undoManager?.canUndo == true)
        #expect(UndoRouting.target(
            responderCanAct: textView.undoManager?.canUndo ?? false,
            appCanAct: true) == .firstResponder)
    }

    /// The other half: an editor nobody has typed in has nothing to give back,
    /// so ⌘Z means what it meant before — the app-level manager acts, and a
    /// window closed a moment ago comes back.
    ///
    /// Left empty rather than seeded with `string`, which would make the
    /// assertion depend on whether a whole-buffer assignment registers an undo
    /// of its own. It has nothing to do with what is being checked here.
    @MainActor
    @Test func anUntouchedEditorLeavesTheAppLevelUndoAlone() {
        let textView = CodeNSTextView()
        textView.allowsUndo = true

        #expect(textView.undoManager?.canUndo == false)
        #expect(UndoRouting.target(
            responderCanAct: textView.undoManager?.canUndo ?? false,
            appCanAct: true) == .application)
    }
}

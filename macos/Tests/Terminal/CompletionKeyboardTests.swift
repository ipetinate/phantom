import AppKit
@testable import Ghostty
import Testing

/// Which keys the completion list and a snippet's tab stops take, and — the
/// half that actually matters — which they leave alone.
///
/// A static over two `Bool`s, so the whole keyboard contract is assertable
/// without a window, an event or a panel. That shape is deliberate: the state
/// lives on the view, but the *decision* must not, or it could only be tested
/// by driving AppKit.
struct CompletionKeyboardTests {
    private func claim(
        _ selector: Selector,
        list: Bool = false,
        snippet: Bool = false
    ) -> CodeNSTextView.Claim? {
        CodeNSTextView.completionCommand(
            for: selector,
            isListOpen: list,
            hasSnippetSession: snippet
        )
    }

    /// Every selector this type has an opinion about, plus a few it must not.
    private let selectors: [Selector] = [
        #selector(NSResponder.moveDown(_:)),
        #selector(NSResponder.moveUp(_:)),
        #selector(NSResponder.scrollPageDown(_:)),
        #selector(NSResponder.scrollPageUp(_:)),
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertTab(_:)),
        #selector(NSResponder.insertBacktab(_:)),
        #selector(NSResponder.cancelOperation(_:)),
        #selector(NSResponder.moveLeft(_:)),
        #selector(NSResponder.deleteBackward(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
    ]

    /// **The invariant the whole design rests on.** With no list and no
    /// snippet, nothing is claimed — so Return still reaches the find bar,
    /// Tab still indents, and Escape still does whatever Escape did before
    /// any of this existed.
    @Test func withNothingOpenNoKeyIsClaimed() {
        for selector in selectors {
            #expect(claim(selector) == nil, "\(selector) was claimed with nothing open")
        }
    }

    @Test func anOpenListTakesTheArrowsAndReturn() {
        #expect(claim(#selector(NSResponder.moveDown(_:)), list: true) == .move(.down))
        #expect(claim(#selector(NSResponder.moveUp(_:)), list: true) == .move(.up))
        #expect(claim(#selector(NSResponder.scrollPageDown(_:)), list: true) == .move(.pageDown))
        #expect(claim(#selector(NSResponder.insertNewline(_:)), list: true) == .accept)
        #expect(claim(#selector(NSResponder.cancelOperation(_:)), list: true) == .dismiss)
    }

    /// An open list does not take keys it has no use for — the caret still
    /// moves left and backspace still deletes while the list is up, which is
    /// what lets a reader refine a query instead of having to close the list
    /// first.
    @Test func anOpenListLeavesEditingKeysAlone() {
        #expect(claim(#selector(NSResponder.moveLeft(_:)), list: true) == nil)
        #expect(claim(#selector(NSResponder.deleteBackward(_:)), list: true) == nil)
    }

    @Test func aSnippetSessionTakesTabAndShiftTab() {
        #expect(claim(#selector(NSResponder.insertTab(_:)), snippet: true) == .nextField)
        #expect(claim(#selector(NSResponder.insertBacktab(_:)), snippet: true) == .previousField)
        #expect(claim(#selector(NSResponder.cancelOperation(_:)), snippet: true) == .dismiss)
    }

    /// A snippet must not take Return. The stops are somewhere inside code
    /// the reader is writing, and Return there means a new line — claiming it
    /// would make an accepted completion swallow the key that ends the
    /// statement.
    @Test func aSnippetSessionLeavesReturnAlone() {
        #expect(claim(#selector(NSResponder.insertNewline(_:)), snippet: true) == nil)
    }

    /// Both live at once: the list wins Tab, because the reader is looking at
    /// a list they just opened and the stop they were on is still there
    /// afterwards.
    @Test func theListWinsTabOverAnActiveSnippet() {
        #expect(claim(#selector(NSResponder.insertTab(_:)), list: true, snippet: true) == .accept)
    }

    /// And Shift-Tab, which the list has no use for, still reaches the stops
    /// underneath it rather than being swallowed.
    @Test func shiftTabReachesTheSnippetEvenWithAListOpen() {
        #expect(claim(#selector(NSResponder.insertBacktab(_:)), list: true, snippet: true) == nil)
    }
}

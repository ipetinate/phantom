import AppKit
@testable import Ghostty
import Testing

/// Every floating panel closes when the view that anchored it loses its
/// window.
///
/// Reported from a live demo: typing `cons` in a split, the completion list
/// open, the tab closed before the list was dismissed or a row accepted. The
/// list stayed exactly where it was for the life of the process.
///
/// The cause is that each panel is a real `NSWindow` added as a child of the
/// editor's window, and AppKit connects nothing between a view leaving and a
/// child window closing. `viewDidMoveToWindow` closed the hover card and only
/// the hover card, which is why that one behaved and the other three did not.
@MainActor
@Suite(.serialized)
struct EditorPanelTeardownTests {
    /// A view in a real window, because the bug is about what happens when the
    /// window goes away — a detached view never had one to lose.
    private func hosted() -> (window: NSWindow, view: CodeNSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let view = CodeNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func panels(over window: NSWindow) -> [NSWindow] {
        window.childWindows ?? []
    }

    /// Opens the list the way a reader does — the provider is the same
    /// property the host sets, and `complete(_:)` is the responder action
    /// bound to Control-Space. Driven through the real path rather than a
    /// test-only hook, so the test cannot pass while the real one is broken.
    private func openCompletions(
        on view: CodeNSTextView,
        _ labels: [String]
    ) async {
        view.completionProvider = { _ in
            .items(labels.map { CodeCompletionItem(kind: .keyword, label: $0) },
                   isIncomplete: false)
        }
        view.complete(nil)

        /// The provider is async, so the list arrives a hop later.
        for _ in 0..<40 where view.completionPanel?.isVisible != true {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theCompletionListDoesNotOutliveTheView() async throws {
        let (window, view) = hosted()
        view.string = "const value = 1"
        view.setSelectedRange(NSRange(location: 4, length: 0))

        await openCompletions(on: view, ["const", "constructor"])
        try #require(view.completionPanel?.isVisible == true,
                     "the list has to be up for this to mean anything")

        /// What closing a tab does to the view.
        view.removeFromSuperview()

        #expect(view.completionPanel?.isVisible != true)
        #expect(panels(over: window).allSatisfy { !$0.isVisible })
    }

    /// The hover card was the one that already worked, because the teardown
    /// named it and nothing else. Pinned so generalising did not lose it.
    @Test func theHoverCardStillGoesToo() async throws {
        let (window, view) = hosted()
        view.string = "const value = 1"
        view.setSelectedRange(NSRange(location: 4, length: 0))

        await openCompletions(on: view, ["const"])
        view.removeFromSuperview()

        #expect(view.hoverPanel?.isVisible != true)
        #expect(panels(over: window).allSatisfy { !$0.isVisible })
    }

    /// Leaving one window for another must not leave a panel hanging over the
    /// window the view left.
    @Test func movingBetweenWindowsLeavesNothingBehind() async throws {
        let (first, view) = hosted()
        view.string = "const value = 1"
        view.setSelectedRange(NSRange(location: 4, length: 0))
        await openCompletions(on: view, ["const"])

        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        view.removeFromSuperview()
        second.contentView?.addSubview(view)

        #expect(panels(over: first).allSatisfy { !$0.isVisible })
    }
}

import AppKit
import Testing
@testable import Ghostty

/// Pins which windows a sidebar may draw a row for.
///
/// The report these come from: with several terminals in one window, clicking
/// a sidebar tab opened a window out of nowhere, and clicking the next one
/// focused the window the previous click had produced. A row is a window, and
/// `select` orders that window front — `makeKeyAndOrderFront` does not refuse
/// a *closed* one, it re-shows it, stripped of the content view and the
/// sidebar chrome that `windowWillClose` already dropped. So a row for a
/// window that is no longer open is not a tab: it is a corpse with a button.
///
/// Windows here are built and never shown, which is exactly the state a
/// closed one reports — no test may order a window front.
@Suite
struct SidebarRowWindowTests {
    @MainActor
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: .init(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true)
    }

    @MainActor
    @Test func aWindowThatIsNotOpenGetsNoRow() {
        let own = makeWindow()
        let other = makeWindow()

        let rows = SidebarTabManager.rowWindows(in: [own, other], own: own)

        #expect(rows == [own])
    }

    /// The sidebar's own window is drawn whatever the predicate says: it is
    /// not on screen while it is initializing, and a list that waits for it to
    /// be would populate empty and stay that way until something else asked
    /// for a refresh.
    @MainActor
    @Test func theSidebarsOwnWindowIsAlwaysARow() {
        let own = makeWindow()

        #expect(SidebarTabManager.rowWindows(in: [own], own: own) == [own])
    }

    /// Position in the group buys a window nothing — the rule is the
    /// predicate, not "the first one wins".
    @MainActor
    @Test func aClosedWindowAheadOfOursIsStillDropped() {
        let first = makeWindow()
        let own = makeWindow()
        let last = makeWindow()

        let rows = SidebarTabManager.rowWindows(in: [first, own, last], own: own)

        #expect(rows == [own])
    }
}

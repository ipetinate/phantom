import Foundation
@testable import Ghostty
import Testing

/// Whether selecting a tab is allowed to fetch its window.
///
/// The bug this rule exists for, reported against 0.13: an agent's command
/// opened a browser, the reader's Space switched to it, something selected a
/// tab — and the terminal window followed them onto the browser's Space, out of
/// the Space they keep it on.
///
/// The mechanism is not obvious and is worth writing down: on macOS,
/// `makeKeyAndOrderFront` on a window that is **not** on the active Space does
/// not switch Spaces, it *moves the window*. Every one of the reader's own
/// selects is safe from that by construction — their click happened in this
/// app, on the Space in front of them. Only a select that arrives from
/// somewhere else can be somewhere else.
@MainActor
struct SidebarSelectSpaceTests {
    /// The reader's own click: the app is active, so ordering front is what
    /// they asked for.
    @Test func aSelectFromInsideTheAppFetchesTheWindow() {
        #expect(SidebarTabManager.mayOrderFront(appIsActive: true, isOnActiveSpace: true))
        #expect(SidebarTabManager.mayOrderFront(appIsActive: true, isOnActiveSpace: false))
    }

    /// The window is already where the reader is looking, so ordering it front
    /// moves nothing between Spaces.
    @Test func aWindowOnTheActiveSpaceIsAlwaysFetched() {
        #expect(SidebarTabManager.mayOrderFront(appIsActive: false, isOnActiveSpace: true))
    }

    /// **The refusal.** The reader is in another app, on another Space, and the
    /// window is not with them: fetching it takes the window out of the Space
    /// they keep it on, which is what was reported.
    @Test func anInactiveAppNeverFetchesAWindowFromAnotherSpace() {
        #expect(!SidebarTabManager.mayOrderFront(appIsActive: false, isOnActiveSpace: false))
    }

    /// The same distinction the rescue beside it needs. A window on another
    /// Space is reported offscreen by the WindowServer and is not a ghost —
    /// `isOnActiveSpace` is what tells the two apart, and without it the rescue
    /// becomes the very fault it was written to repair.
    @Test func theTwoReasonsAWindowIsNotOnScreenAreNotTheSame() {
        #expect(WindowGhostRescue.shouldRescue(
            appIsActive: true,
            aTerminalIsKey: false,
            aTerminalIsOnTheActiveSpace: false,
            reachableTerminals: 1))

        #expect(!WindowGhostRescue.shouldRescue(
            appIsActive: true,
            aTerminalIsKey: false,
            aTerminalIsOnTheActiveSpace: true,
            reachableTerminals: 1))
    }
}

import AppKit
import Testing
@testable import Ghostty

/// How ⌘Q leaves the key-equivalent dispatch.
///
/// The regression these hold: performing the Quit menu item from inside
/// `performKeyEquivalent` — which is where a focused surface routes its
/// Ghostty bindings — sent `terminate:` down a path that reached `exit()`
/// without ever consulting `applicationShouldTerminate` or
/// `applicationWillTerminate`. Observed under lldb with a breakpoint at
/// `exit` and a regex breakpoint on the delegate: only `exit` fired. No
/// confirmation over running processes, no final session save; the quit was
/// indistinguishable from a crash and lost whatever the debounced save had
/// not flushed.
@MainActor
struct QuitRouteTests {
    /// A quit-bound item is answered by the deferred route, and the menu
    /// item itself is never performed.
    @Test func aQuitItemIsDeferredNotPerformed() {
        let item = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let original = Ghostty.MenuShortcutManager.deferredQuit
        defer { Ghostty.MenuShortcutManager.deferredQuit = original }
        var deferred = 0
        Ghostty.MenuShortcutManager.deferredQuit = { deferred += 1 }

        #expect(Ghostty.MenuShortcutManager.handledAsDeferredQuit(item))
        #expect(deferred == 1)
    }

    /// Every other action stays on the menu-perform path — the deferral is
    /// for the one selector whose in-dispatch performance bypassed the app
    /// delegate, not a new routing layer for the menu bar.
    @Test func anyOtherItemIsLeftToTheMenu() {
        let item = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")

        let original = Ghostty.MenuShortcutManager.deferredQuit
        defer { Ghostty.MenuShortcutManager.deferredQuit = original }
        var deferred = 0
        Ghostty.MenuShortcutManager.deferredQuit = { deferred += 1 }

        #expect(!Ghostty.MenuShortcutManager.handledAsDeferredQuit(item))
        #expect(deferred == 0)
    }
}

import Foundation
@testable import Ghostty
import Testing

/// When a Dock click gets verified, and when the verification acts.
///
/// The incident this pins: a restored window, in use for hours, was found
/// orphaned on a Space that no longer existed — listed by Mission Control,
/// unraisable by it, and the Dock click did nothing because macOS counted the
/// orphan as a visible window and considered its work done. The only thing
/// that recovered it was `makeKeyAndOrderFront`, reached by accident through
/// a sidebar click.
struct WindowGhostRescueTests {
    private func rescues(
        active: Bool = true,
        key: Bool = false,
        onSpace: Bool = false,
        reachable: Int = 1
    ) -> Bool {
        WindowGhostRescue.shouldRescue(
            appIsActive: active,
            aTerminalIsKey: key,
            aTerminalIsOnTheActiveSpace: onSpace,
            reachableTerminals: reachable)
    }

    /// The incident itself: app active, a window exists somewhere, nothing
    /// reached the reader.
    @Test func anActiveAppWithNoTerminalAnywhereNearTheReaderIsRescued() {
        #expect(rescues())
    }

    /// The Dock click worked — a terminal is key. Acting here would reorder
    /// windows under a reader who is already looking at one.
    @Test func aTerminalThatBecameKeyMeansTheReopenWorked() {
        #expect(!rescues(key: true))
    }

    /// A healthy Space switch: macOS moved the reader to the window's Space.
    /// The window never becomes key-less-and-absent, and dragging it off its
    /// Space would undo the reader's own arrangement.
    @Test func aTerminalOnTheActiveSpaceNeedsNoRescue() {
        #expect(!rescues(onSpace: true))
    }

    /// The check runs on a delay, and the reader may have switched apps in
    /// the meantime. Pulling a window forward under another app is worse
    /// than the ghost.
    @Test func anInactiveAppIsLeftAlone() {
        #expect(!rescues(active: false))
    }

    /// Nothing to rescue is the reopen handler's own case — it opens a new
    /// window — and ordering front a window that does not exist is not a
    /// thing to attempt.
    @Test func nothingReachableMeansNothingToRescue() {
        #expect(!rescues(reachable: 0))
    }

    /// Long enough for a Space-switch animation to finish, short enough that
    /// the rescue does not read as another failed click. The exact number is
    /// judgement; that it is at least the length of an animation is not.
    @Test func theVerificationWaitsOutASpaceSwitch() {
        #expect(WindowGhostRescue.verificationDelay >= 0.5)
        #expect(WindowGhostRescue.verificationDelay <= 2)
    }
}

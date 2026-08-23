import AppKit
import Testing
@testable import Ghostty

/// A window that records what the reveal asked of it, without ever letting
/// AppKit act on the request — `orderFrontRegardless` on a real test window
/// would put it on the developer's screen.
private final class RevealSpyWindow: NSWindow {
    var orderedFront = 0
    var madeKey = 0

    override func orderFrontRegardless() { orderedFront += 1 }
    override func makeKey() { madeKey += 1 }
}

/// The two regressions `PhantomSessionStore.scheduleReveal` exists to hold.
///
/// The first shipped and was caught on screen: a reveal issued synchronously
/// from inside `applicationShouldHandleReopen` left the whole restored group
/// AppKit-visible and WindowServer-offscreen — `isVisible` true, sane frame,
/// `CGWindowListCopyWindowInfo` answering `onscreen=false`, the app active
/// with no window at all. Partially committed, the same defect was the tab
/// that selects but never draws.
///
/// The second shipped in the fix for the first: deferred but ordered front
/// without `makeKey`, the app came back with a dead menu bar — every
/// first-responder action, File → Close Window included, landed on nobody.
@MainActor
struct SessionRevealTests {
    private func makeSpy() -> RevealSpyWindow {
        let spy = RevealSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        spy.isReleasedWhenClosed = false
        return spy
    }

    /// Nothing may happen inside the calling dispatch. The queue is held
    /// suspended for the length of the assertion, so any synchronous
    /// ordering — the regression — is caught as a count that moved too
    /// early.
    @Test func theRevealDoesNothingSynchronously() {
        let spy = makeSpy()
        let queue = DispatchQueue(label: "reveal-test")
        queue.suspend()

        PhantomSessionStore.scheduleReveal(of: spy, on: queue)

        #expect(spy.orderedFront == 0)
        #expect(spy.madeKey == 0)
        queue.resume()
        queue.sync {}
    }

    /// Once the turn arrives, the window is ordered front **and** made key,
    /// and only then does the follow-up run — the follow-up corrects the tab
    /// group's selection, which only exists to correct once the group is on
    /// screen.
    @Test func theDeferredTurnOrdersFrontMakesKeyThenFollowsUp() {
        let spy = makeSpy()
        let queue = DispatchQueue(label: "reveal-test")
        var stateAtFollowUp: (front: Int, key: Int)?

        PhantomSessionStore.scheduleReveal(of: spy, on: queue) {
            stateAtFollowUp = (spy.orderedFront, spy.madeKey)
        }
        queue.sync {}

        #expect(spy.orderedFront == 1)
        #expect(spy.madeKey == 1)
        #expect(stateAtFollowUp?.front == 1)
        #expect(stateAtFollowUp?.key == 1)
    }
}

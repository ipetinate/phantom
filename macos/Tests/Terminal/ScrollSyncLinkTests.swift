import AppKit
@testable import Ghostty
import Testing

/// The link driving two real scroll views, with no window anywhere.
///
/// `NSScrollView` and `NSClipView` are ordinary views: they lay out, they
/// move their bounds and they post about it without ever being shown. So
/// these tests build the real thing rather than a stand-in, and not one of
/// them goes near `orderFront` — asking the window server to display
/// anything from this host, which has no `NSApplication` event loop pumping
/// the replies, never returns.
///
/// Relays are driven two ways on purpose. Most tests call `relay(from:)`
/// directly, because what is under test is the decision and AppKit makes no
/// promise about *when* a clip view posts its bounds change. Two tests post
/// the notification themselves, to prove the observer is on the right
/// object and routes to the right side — the part direct calls skip.
@MainActor
struct ScrollSyncLinkTests {
    /// Flipped, because the link reads a clip view's origin as a distance
    /// from the top and everything that scrolls in this app is flipped.
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func scrollView(contentHeight: CGFloat, viewportHeight: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 300, height: viewportHeight)
        )
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = DocumentView(
            frame: NSRect(x: 0, y: 0, width: 300, height: contentHeight)
        )
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    /// A leader with 800 points of travel and a follower with 400, so
    /// proportional and absolute cannot be mistaken for one another.
    private func pair() -> (leader: NSScrollView, follower: NSScrollView) {
        (
            scrollView(contentHeight: 1000, viewportHeight: 200),
            scrollView(contentHeight: 600, viewportHeight: 200)
        )
    }

    private func move(_ scrollView: NSScrollView, to offset: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func offset(of scrollView: NSScrollView) -> CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    /// Guards the guards. Every expectation below is arithmetic on these
    /// two numbers, so a clip view that came out a different size than the
    /// frame it was given would fail everything with numbers that look
    /// almost right.
    @Test func theTestsScrollViewsAreTheSizeTheySay() {
        let (leader, _) = pair()
        #expect(leader.contentView.bounds.height == CGFloat(200))
        #expect(leader.documentView?.frame.height == CGFloat(1000))
    }

    // MARK: - Wiring

    @Test func attachingAsksTheClipViewToReport() {
        let (leader, _) = pair()
        let link = ScrollSyncLink()
        link.attach(leader, as: .first)

        #expect(leader.contentView.postsBoundsChangedNotifications)
        #expect(link.scrollView(for: .first) === leader)
        #expect(link.scrollView(for: .second) == nil)
    }

    @Test func detachingLetsGo() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .absolute, isEnabled: true)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)
        link.detach(.second)

        move(leader, to: 300)
        link.relay(from: .first)

        #expect(link.scrollView(for: .second) == nil)
        #expect(offset(of: follower) == CGFloat(0))
    }

    // MARK: - Opt-in

    @Test func aLinkNobodyTurnedOnMovesNothing() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .absolute)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        move(leader, to: 300)
        link.relay(from: .first)

        #expect(!link.isEnabled)
        #expect(offset(of: follower) == CGFloat(0))
    }

    @Test func turningItOnMakesTheFollowerFollow() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .proportional, isEnabled: true)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        move(leader, to: 400)
        link.relay(from: .first)

        #expect(offset(of: follower) == CGFloat(200))
    }

    /// Either pane can lead. Nothing in the link makes the first one
    /// special, and a diff whose reader scrolls the right-hand side would
    /// notice immediately if it did.
    @Test func eitherSideCanLead() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .proportional, isEnabled: true)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        move(follower, to: 100)
        link.relay(from: .second)

        #expect(offset(of: leader) == CGFloat(200))
    }

    // MARK: - The feedback loop

    /// The loop, broken, and the proof that it was broken by the right
    /// thing.
    ///
    /// Both halves are the same call — `relay(from: .second)` right after
    /// the follower's offset changed. The first is the echo of the link's
    /// own write and must go nowhere; the second is the reader's hand on
    /// the same pane and must reach the leader. Only the *value* tells them
    /// apart, which is exactly what the echo filter is for, and a test that
    /// checked only the first half would also pass if the link had simply
    /// stopped listening to the follower.
    @Test func theFollowersEchoDoesNotDragTheLeaderBack() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .proportional, isEnabled: true)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        move(leader, to: 400)
        link.relay(from: .first)
        #expect(offset(of: follower) == CGFloat(200))

        link.relay(from: .second)
        #expect(offset(of: leader) == CGFloat(400))

        move(follower, to: 300)
        link.relay(from: .second)
        #expect(offset(of: leader) == CGFloat(600))
    }

    /// Left to run, an unbroken loop under `.proportional` walks the two
    /// panes to their ends a few points at a time. Forty hops is far more
    /// than the drift needs to become visible, so a leader still sitting
    /// where it was put is the whole claim.
    @Test func relayingBackAndForthSettlesInsteadOfDrifting() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .proportional, isEnabled: true)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        move(leader, to: 400)
        for _ in 0..<20 {
            link.relay(from: .first)
            link.relay(from: .second)
        }

        #expect(offset(of: leader) == CGFloat(400))
        #expect(offset(of: follower) == CGFloat(200))
    }

    /// An asymmetric mapping leans on the echo filter harder than anything
    /// else does, so it gets its own test.
    ///
    /// `.absolute` survives a stray round trip by luck — its round trip is
    /// the identity. This mapping's is not: it adds a hundred points each
    /// way, so a single unfiltered echo would walk the panes to their ends
    /// and stay there. That is the shape of every raw-to-rendered mapping,
    /// where the two directions are unrelated functions and nothing brings
    /// a round trip home.
    ///
    /// Both halves again: the echo suppressed, and a real scroll of the same
    /// pane still getting through.
    @Test func anAsymmetricStrategysEchoIsStillSwallowed() {
        let (leader, follower) = (
            scrollView(contentHeight: 1000, viewportHeight: 200),
            scrollView(contentHeight: 1000, viewportHeight: 200)
        )
        let link = ScrollSyncLink(
            strategy: ScrollSyncStrategy { geometry, _ in geometry.leaderOffset + 100 },
            isEnabled: true
        )
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        move(leader, to: 100)
        link.relay(from: .first)
        #expect(offset(of: follower) == CGFloat(200))

        link.relay(from: .second)
        #expect(offset(of: leader) == CGFloat(100))

        move(follower, to: 500)
        link.relay(from: .second)
        #expect(offset(of: leader) == CGFloat(600))
    }

    /// The side reaching the mapping is the side that *moved*, not always
    /// `.first`. Getting this backwards would apply a raw-to-rendered map to
    /// the rendered pane and vice versa — wrong in both directions at once,
    /// and invisible under any symmetric strategy.
    @Test func theMappingIsToldWhichSideActuallyMoved() {
        let (leader, follower) = pair()
        let seen = SideLog()
        let link = ScrollSyncLink(
            strategy: ScrollSyncStrategy { geometry, side in
                seen.sides.append(side)
                return geometry.leaderOffset
            },
            isEnabled: true
        )
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        link.relay(from: .second)
        link.relay(from: .first)

        #expect(seen.sides == [.second, .first])
    }

    private final class SideLog {
        var sides: [ScrollSyncSide] = []
    }

    // MARK: - Through the notification

    /// Proves the observer is registered against the right clip view and
    /// routes to the right side. Posted by hand rather than by scrolling,
    /// so the test asserts the wiring and not AppKit's coalescing schedule.
    @Test func aBoundsChangeOnTheLeaderReachesTheFollower() {
        let (leader, follower) = pair()
        let link = ScrollSyncLink(strategy: .absolute, isEnabled: true)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        leader.contentView.bounds.origin = NSPoint(x: 0, y: 250)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: leader.contentView
        )

        #expect(offset(of: follower) == CGFloat(250))
    }

    /// Attaching is idempotent, and it has to be: `updateNSView` runs on
    /// every SwiftUI pass, so a second registration would double every
    /// relay for the rest of the pane's life.
    @Test func attachingTwiceRegistersOnce() {
        let (leader, follower) = pair()
        let counter = Counter()
        let link = ScrollSyncLink(
            strategy: ScrollSyncStrategy { geometry, _ in
                counter.count += 1
                return geometry.leaderOffset
            },
            isEnabled: true
        )
        link.attach(leader, as: .first)
        link.attach(leader, as: .first)
        link.attach(follower, as: .second)

        /// Posted without moving anything. The strategy is consulted once
        /// per routed notification whether or not the follower ends up
        /// moving, so counting it needs no scroll — and a scroll would risk
        /// AppKit posting a notification of its own on top of this one,
        /// which is the very ambiguity this test exists to rule out.
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: leader.contentView
        )

        #expect(counter.count == 1)
    }

    /// Replacing one side's scroll view unregisters the old one, so a pane
    /// whose content was swapped does not keep a dead view driving the
    /// living one.
    @Test func attachingASecondScrollViewReplacesTheFirst() {
        let (leader, follower) = pair()
        let replacement = scrollView(contentHeight: 1000, viewportHeight: 200)
        let counter = Counter()
        let link = ScrollSyncLink(
            strategy: ScrollSyncStrategy { geometry, _ in
                counter.count += 1
                return geometry.leaderOffset
            },
            isEnabled: true
        )
        link.attach(leader, as: .first)
        link.attach(replacement, as: .first)
        link.attach(follower, as: .second)

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: leader.contentView
        )

        #expect(link.scrollView(for: .first) === replacement)
        #expect(counter.count == 0)
        #expect(offset(of: follower) == CGFloat(0))
    }

    // MARK: - The SwiftUI side's probe

    /// The other half of the attachment story. A pane made of SwiftUI never
    /// holds its `NSScrollView`, so the probe goes looking for it — and this
    /// is that search, run against a real hierarchy rather than trusted.
    @Test func aProbePlacedInsideAScrollViewHandsItOver() {
        let scrollView = self.scrollView(contentHeight: 1000, viewportHeight: 200)
        let link = ScrollSyncLink()
        let probe = ScrollSyncProbeView()
        probe.onAttach = { link.attach($0, as: .first) }

        scrollView.documentView?.addSubview(probe)

        #expect(link.scrollView(for: .first) === scrollView)
    }

    /// A pane taken off screen must take its half of the link with it, or a
    /// scroll view nobody can see any more goes on driving the one that is
    /// still there.
    @Test func aProbeLeavingItsScrollViewLetsGo() {
        let scrollView = self.scrollView(contentHeight: 1000, viewportHeight: 200)
        let link = ScrollSyncLink()
        let probe = ScrollSyncProbeView()
        probe.onAttach = { link.attach($0, as: .first) }
        probe.onDetach = { link.detach(.first) }

        scrollView.documentView?.addSubview(probe)
        probe.removeFromSuperview()

        #expect(link.scrollView(for: .first) == nil)
    }

    /// `.background` puts the probe behind the pane's content, and a
    /// rendered document is mostly gaps. A probe that answered a hit test
    /// would swallow every drag that began on a blank line.
    @Test func aProbeNeverTakesAClick() {
        let probe = ScrollSyncProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(probe.hitTest(NSPoint(x: 50, y: 50)) == nil)
    }

    private final class Counter {
        var count = 0
    }
}

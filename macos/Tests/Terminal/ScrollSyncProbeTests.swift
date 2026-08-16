import AppKit
import SwiftUI
@testable import Ghostty
import Testing

/// The half of scroll sync that only a real SwiftUI hierarchy can answer.
///
/// `ScrollSyncLinkTests` proves the link moves panes; this proves the panes
/// ever reach the link. A SwiftUI `ScrollView` is backed by an
/// `NSScrollView` nobody in the host's code holds, so the probe has to find
/// it — and whether it does depends entirely on where SwiftUI puts a
/// `.background` view and when it assembles the tree. Neither is knowable by
/// reading the code, and both were wrong at first: the probe resolved before
/// its host was in the tree and never looked again, so **the documented
/// usage attached nothing at all**.
///
/// `NSHostingView` lays a real tree out with no window and no run loop —
/// `layoutSubtreeIfNeeded()` drives the probe's `layout()` synchronously —
/// so none of this goes near `orderFront`.
///
/// Every test keeps its host alive across the assertions on purpose: the
/// link holds its scroll views **weakly**, so a host released early would
/// nil them out and the failure would read as "the probe never attached".
@MainActor
struct ScrollSyncProbeTests {
    /// Stands in for `GitDiffPane`: a view whose *body* is a `ScrollView`,
    /// scrolling both ways as the diff's columns do.
    private struct Pane: View {
        var contentHeight: CGFloat = 1000

        var body: some View {
            ScrollView([.vertical, .horizontal]) {
                Color.gray.frame(width: 900, height: contentHeight)
            }
        }
    }

    private func host(_ view: some View, width: CGFloat = 300) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Gives a hosted scroll view's document a size, which is the one thing
    /// a windowless layout will not supply.
    ///
    /// Measured rather than assumed: after `layoutSubtreeIfNeeded()` the
    /// clip view comes out correctly sized — 300×200, the frame it was given
    /// — while the document view is **0×0**, because SwiftUI does not lay
    /// its content out without a window to draw into. A document of no
    /// height has nothing to scroll, so `scroll(to:)` clamps straight back
    /// to zero and every assertion below reads as "the link did nothing".
    ///
    /// Only the content's *size* is stood in for here. The scroll view, the
    /// clip view, the probe and the link are all the real ones, so what
    /// these tests prove is the wiring; what they cannot prove is that
    /// SwiftUI gives the content a sensible size on screen.
    private func giveDocumentAHeight(_ scrollView: NSScrollView, _ height: CGFloat) {
        scrollView.documentView?.setFrameSize(NSSize(width: 900, height: height))
        scrollView.layoutSubtreeIfNeeded()
    }

    // MARK: - Where the modifier is written

    /// The placement the modifier's documentation asks for.
    @Test func aProbeInsideTheScrollViewAttaches() {
        let link = ScrollSyncLink()
        let container = host(
            ScrollView {
                Color.gray.frame(width: 300, height: 1000)
                    .synchronizedScroll(link, as: .first)
            }
        )

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) != nil)
        }
    }

    /// The placement everyone actually writes, and the reason the probe
    /// searches sideways rather than only upwards.
    ///
    /// `.background` on a view whose body is a `ScrollView` lands the probe
    /// *beside* that scroll view, so `enclosingScrollView` walks straight
    /// past it. Both features wrote it this way before anyone noticed, which
    /// is a fact about the API rather than about them.
    @Test func aProbeOnAPaneWhoseBodyIsAScrollViewAttaches() {
        let link = ScrollSyncLink()
        let container = host(Pane().synchronizedScroll(link, as: .first))

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) != nil)
        }
    }

    @Test func aProbeDirectlyOnAScrollViewAttaches() {
        let link = ScrollSyncLink()
        let container = host(
            ScrollView { Color.gray.frame(width: 300, height: 1000) }
                .synchronizedScroll(link, as: .first)
        )

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) != nil)
        }
    }

    // MARK: - Two panes at once

    /// The arrangement this whole component exists for, and the one a
    /// careless search gets wrong.
    ///
    /// Both probes can see both scroll views from where they stand. Linking
    /// them to the *same* one would look like working sync until the moment
    /// a reader noticed only one column ever moved, so the panes being
    /// **different** is the assertion that matters here.
    @Test func twoPanesSideBySideEachFindTheirOwn() {
        let link = ScrollSyncLink()
        let container = host(
            HStack(spacing: 0) {
                Pane().synchronizedScroll(link, as: .first)
                Pane().synchronizedScroll(link, as: .second)
            },
            width: 600
        )

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) != nil)
            #expect(link.scrollView(for: .second) != nil)
            #expect(link.scrollView(for: .first) !== link.scrollView(for: .second))
        }
    }

    /// `GitDiffPane`'s real shape, which wraps its `ScrollView` in a
    /// `GeometryReader` to size rows against the viewport.
    ///
    /// Written out rather than folded into `Pane` because the wrapper adds a
    /// level to the hierarchy the probe climbs, and the climb is capped. A
    /// consumer nesting its scroll view one container deeper is exactly how
    /// this quietly stops working, so the shape in use is pinned here.
    @Test func aPaneThatWrapsItsScrollViewInAGeometryReaderStillAttaches() {
        struct GeometryPane: View {
            var body: some View {
                GeometryReader { viewport in
                    ScrollView([.vertical, .horizontal]) {
                        Color.gray
                            .frame(width: max(900, viewport.size.width), alignment: .leading)
                            .frame(minHeight: viewport.size.height, alignment: .top)
                    }
                }
            }
        }

        let link = ScrollSyncLink()
        let container = host(
            HStack(spacing: 0) {
                GeometryPane().synchronizedScroll(link, as: .first)
                GeometryPane().synchronizedScroll(link, as: .second)
            },
            width: 600
        )

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) != nil)
            #expect(link.scrollView(for: .second) != nil)
            #expect(link.scrollView(for: .first) !== link.scrollView(for: .second))
        }
    }

    /// The same, stacked — which is the other thing the direction toggle
    /// produces, and a different SwiftUI container.
    @Test func twoPanesStackedEachFindTheirOwn() {
        let link = ScrollSyncLink()
        let container = host(
            VStack(spacing: 0) {
                Pane().synchronizedScroll(link, as: .first)
                Pane().synchronizedScroll(link, as: .second)
            }
        )

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) != nil)
            #expect(link.scrollView(for: .second) != nil)
            #expect(link.scrollView(for: .first) !== link.scrollView(for: .second))
        }
    }

    // MARK: - A pane that does not scroll

    /// The diff draws a line of text instead of columns when a file has no
    /// changes on one side, and that pane has no scroll view to give.
    ///
    /// Attaching **nothing** is the right answer, and it is not the obvious
    /// one: an earlier version of the search widened its net when the pane
    /// it backed came up empty, found the *neighbour's* scroll view, and
    /// pointed both sides of the link at a single pane.
    @Test func aPaneWithNoScrollViewAttachesNothingRatherThanItsNeighbours() {
        let link = ScrollSyncLink()
        let container = host(
            HStack(spacing: 0) {
                Text("No changes on this side.")
                    .synchronizedScroll(link, as: .first)
                Pane().synchronizedScroll(link, as: .second)
            },
            width: 600
        )

        withExtendedLifetime(container) {
            #expect(link.scrollView(for: .first) == nil)
            #expect(link.scrollView(for: .second) != nil)
        }
    }

    /// One side missing leaves the other harmless rather than broken: a
    /// relay with nobody to relay to does nothing and corrupts nothing, so
    /// the link is still good when the pane comes back.
    @Test func aHalfAttachedLinkRelaysNothingAndSurvivesIt() {
        let link = ScrollSyncLink(strategy: .absolute, isEnabled: true)
        let container = host(
            HStack(spacing: 0) {
                Text("No changes on this side.")
                    .synchronizedScroll(link, as: .first)
                Pane().synchronizedScroll(link, as: .second)
            },
            width: 600
        )

        withExtendedLifetime(container) {
            guard let attached = link.scrollView(for: .second) else {
                Issue.record("the scrolling pane never attached")
                return
            }

            giveDocumentAHeight(attached, 1000)
            attached.contentView.scroll(to: NSPoint(x: 0, y: 120))
            link.relay(from: .second)

            #expect(link.scrollView(for: .first) == nil)
            #expect(attached.contentView.bounds.origin.y == CGFloat(120))
        }
    }

    // MARK: - End to end

    /// Scrolling one hosted pane moves the other, through the whole chain:
    /// SwiftUI builds the scroll views, the probes find them, the clip view
    /// reports, and the link answers.
    ///
    /// `.absolute` with two panes of equal length, so the expected number is
    /// the leader's own offset and the assertion does not depend on
    /// measuring a viewport whose height AppKit may inset for a scroller.
    @Test func scrollingOnePaneMovesTheOther() {
        let link = ScrollSyncLink(strategy: .absolute, isEnabled: true)
        let container = host(
            HStack(spacing: 0) {
                Pane().synchronizedScroll(link, as: .first)
                Pane().synchronizedScroll(link, as: .second)
            },
            width: 600
        )

        withExtendedLifetime(container) {
            guard let leader = link.scrollView(for: .first),
                  let follower = link.scrollView(for: .second)
            else {
                Issue.record("the panes never attached")
                return
            }

            giveDocumentAHeight(leader, 1000)
            giveDocumentAHeight(follower, 1000)

            leader.contentView.scroll(to: NSPoint(x: 0, y: 250))
            leader.reflectScrolledClipView(leader.contentView)
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: leader.contentView
            )

            #expect(leader.contentView.bounds.origin.y == CGFloat(250))
            #expect(follower.contentView.bounds.origin.y == CGFloat(250))
        }
    }

    /// And the echo does not come back, in the real hierarchy rather than
    /// against hand-built scroll views.
    @Test func theFollowerDoesNotDragTheLeaderBackInARealHierarchy() {
        let link = ScrollSyncLink(strategy: .proportional, isEnabled: true)
        let container = host(
            HStack(spacing: 0) {
                Pane(contentHeight: 1000).synchronizedScroll(link, as: .first)
                Pane(contentHeight: 600).synchronizedScroll(link, as: .second)
            },
            width: 600
        )

        withExtendedLifetime(container) {
            guard let leader = link.scrollView(for: .first),
                  let follower = link.scrollView(for: .second)
            else {
                Issue.record("the panes never attached")
                return
            }

            giveDocumentAHeight(leader, 1000)
            giveDocumentAHeight(follower, 600)

            leader.contentView.scroll(to: NSPoint(x: 0, y: 400))
            leader.reflectScrolledClipView(leader.contentView)

            for _ in 0..<20 {
                link.relay(from: .first)
                link.relay(from: .second)
            }

            #expect(leader.contentView.bounds.origin.y == CGFloat(400))
        }
    }
}

import Foundation
@testable import Ghostty
import Testing

/// Every decision the scroll link makes, made without a scroll view.
///
/// The point of pushing the arithmetic into `ScrollSyncStrategy` was that
/// this file can exist: two panes at made-up sizes, a mapping, an answer.
/// Nothing here builds a view, so nothing here can hang the suite waiting
/// for a window server that the test host has no event loop to talk to.
///
/// Every float assertion names `CGFloat` on both sides. `#expect` does not
/// apply the implicit conversion the compiler would in ordinary code, and a
/// bare literal compared against a `CGFloat` has failed here before while
/// printing two identical-looking numbers.
struct ScrollSyncTests {
    /// A leader 1000 long showing 200 of itself: 800 points of travel.
    private func leader(offset: CGFloat) -> ScrollPaneMetrics {
        ScrollPaneMetrics(
            offset: CGPoint(x: 0, y: offset),
            contentSize: CGSize(width: 300, height: 1000),
            viewportSize: CGSize(width: 300, height: 200)
        )
    }

    /// A follower 600 long showing 200: 400 points of travel, half the
    /// leader's. Deliberately a different length — two panes that happen to
    /// match would let a proportional bug pass as an absolute one.
    private func follower(offset: CGFloat = 0) -> ScrollPaneMetrics {
        ScrollPaneMetrics(
            offset: CGPoint(x: 0, y: offset),
            contentSize: CGSize(width: 300, height: 600),
            viewportSize: CGSize(width: 300, height: 200)
        )
    }

    private func geometry(
        leaderOffset: CGFloat,
        leaderContent: CGFloat = 1000,
        leaderViewport: CGFloat = 200,
        followerContent: CGFloat = 600,
        followerViewport: CGFloat = 200
    ) -> ScrollSyncGeometry {
        ScrollSyncGeometry(
            leaderOffset: leaderOffset,
            leaderContentLength: leaderContent,
            leaderViewportLength: leaderViewport,
            followerContentLength: followerContent,
            followerViewportLength: followerViewport
        )
    }

    // MARK: - Geometry

    @Test func aPaneThatFitsItsViewportHasNowhereToGo() {
        let short = geometry(leaderOffset: 0, leaderContent: 120, leaderViewport: 400)
        #expect(short.leaderScrollableLength == CGFloat(0))
        #expect(short.leaderProgress == CGFloat(0))
    }

    /// Rubber-band overscroll reports an offset past the end. It is a real
    /// thing a trackpad does, and the follower must not be sent past its own
    /// end to match.
    @Test func overscrollDoesNotPushProgressPastTheEnd() {
        #expect(geometry(leaderOffset: 950).leaderProgress == CGFloat(1))
        #expect(geometry(leaderOffset: -40).leaderProgress == CGFloat(0))
    }

    // MARK: - Absolute

    @Test func absolutePutsTheFollowerAtTheLeadersOwnOffset() {
        let offset = ScrollSyncStrategy.absolute.followerOffset(
            for: geometry(leaderOffset: 250, followerContent: 1000),
            from: .first
        )
        #expect(offset == CGFloat(250))
    }

    /// The case a padded diff still runs into: the two sides are the same
    /// length until a trailing newline difference makes one a row shorter.
    @Test func absoluteStopsAtTheFollowersEnd() {
        let offset = ScrollSyncStrategy.absolute.followerOffset(
            for: geometry(leaderOffset: 700),
            from: .first
        )
        #expect(offset == CGFloat(400))
    }

    // MARK: - Proportional

    @Test func proportionalMatchesHowFarThroughEachPaneIs() {
        let offset = ScrollSyncStrategy.proportional.followerOffset(
            for: geometry(leaderOffset: 400),
            from: .first
        )
        #expect(offset == CGFloat(200))
    }

    @Test func proportionalMatchesTheEnds() {
        #expect(
            ScrollSyncStrategy.proportional
                .followerOffset(for: geometry(leaderOffset: 0), from: .first) == CGFloat(0)
        )
        #expect(
            ScrollSyncStrategy.proportional
                .followerOffset(for: geometry(leaderOffset: 800), from: .first) == CGFloat(400)
        )
    }

    /// A rendered preview shorter than its viewport has nothing to scroll,
    /// and scrolling the raw text beside it must not try to move it anyway.
    @Test func aFollowerWithNoTravelStaysPut() {
        let offset = ScrollSyncStrategy.proportional.followerOffset(
            for: geometry(leaderOffset: 400, followerContent: 150, followerViewport: 400),
            from: .first
        )
        #expect(offset == CGFloat(0))
    }

    // MARK: - Clamping a host's own mapping

    /// The clamp is in `followerOffset(for:from:)` rather than in each mapping
    /// precisely so a host cannot skip it.
    @Test func aMappingThatOvershootsIsBroughtBackToTheEnd() {
        let runaway = ScrollSyncStrategy { _, _ in 99_999 }
        #expect(
            runaway.followerOffset(for: geometry(leaderOffset: 10), from: .first) == CGFloat(400)
        )
    }

    @Test func aMappingThatGoesNegativeIsBroughtBackToTheTop() {
        let underflow = ScrollSyncStrategy { _, _ in -500 }
        #expect(
            underflow.followerOffset(for: geometry(leaderOffset: 10), from: .first) == CGFloat(0)
        )
    }

    // MARK: - Row alignment

    /// The diff's case: row 2 of the leader is row 5 of the follower, and
    /// the five points the reader is scrolled into that row come along.
    @Test func rowAlignmentCarriesThePartRowOver() {
        let strategy = ScrollSyncStrategy.rowAligned(
            rowHeight: 20,
            firstToSecond: { $0 + 3 },
            secondToFirst: { $0 - 3 }
        )
        let offset = strategy.followerOffset(
            for: geometry(leaderOffset: 45, followerContent: 1000),
            from: .first
        )
        #expect(offset == CGFloat(105))
    }

    @Test func rowAlignmentWithoutARowHeightFallsBackToTheLeadersOffset() {
        let strategy = ScrollSyncStrategy.rowAligned(
            rowHeight: 0,
            firstToSecond: { $0 },
            secondToFirst: { $0 }
        )
        let offset = strategy.followerOffset(
            for: geometry(leaderOffset: 50, followerContent: 1000),
            from: .first
        )
        #expect(offset == CGFloat(50))
    }

    // MARK: - Which side is leading

    /// The whole point of telling the mapping which side moved.
    ///
    /// Raw markdown against its rendered form needs two different functions,
    /// and nothing about the geometry says which one to use — both
    /// directions see a leader offset and two content lengths. Only the side
    /// distinguishes them.
    @Test func anAsymmetricMappingGetsADifferentAnswerForEachDirection() {
        let strategy = ScrollSyncStrategy { geometry, side in
            side == .first ? geometry.leaderOffset * 2 : geometry.leaderOffset / 2
        }

        let leading = strategy.followerOffset(
            for: geometry(leaderOffset: 100, followerContent: 5000),
            from: .first
        )
        let following = strategy.followerOffset(
            for: geometry(leaderOffset: 100, followerContent: 5000),
            from: .second
        )

        #expect(leading == CGFloat(200))
        #expect(following == CGFloat(50))
    }

    /// The two mappings the built-ins are: unchanged by the new argument, so
    /// a diff keeps behaving exactly as it did.
    @Test func theBuiltInMappingsIgnoreWhichSideIsLeading() {
        let shape = geometry(leaderOffset: 400)

        #expect(
            ScrollSyncStrategy.absolute.followerOffset(for: shape, from: .first)
                == ScrollSyncStrategy.absolute.followerOffset(for: shape, from: .second)
        )
        #expect(
            ScrollSyncStrategy.proportional.followerOffset(for: shape, from: .first)
                == ScrollSyncStrategy.proportional.followerOffset(for: shape, from: .second)
        )
    }

    /// Row alignment takes both directions because an unpadded diff's
    /// alignment is not invertible: a run of deleted lines puts several
    /// left-hand rows opposite one right-hand row, so `secondToFirst` cannot
    /// be derived from `firstToSecond`.
    @Test func rowAlignmentUsesTheMapForTheDirectionBeingScrolled() {
        let strategy = ScrollSyncStrategy.rowAligned(
            rowHeight: 20,
            firstToSecond: { $0 + 3 },
            secondToFirst: { max(0, $0 - 3) }
        )

        let shape = geometry(leaderOffset: 100, followerContent: 1000)
        #expect(strategy.followerOffset(for: shape, from: .first) == CGFloat(160))
        #expect(strategy.followerOffset(for: shape, from: .second) == CGFloat(40))
    }

    // MARK: - Axes

    @Test func verticalSyncLeavesTheFollowerWhereItIsSideways() {
        let origin = ScrollSyncStrategy.proportional.followerOrigin(
            leader: ScrollPaneMetrics(
                offset: CGPoint(x: 120, y: 400),
                contentSize: CGSize(width: 900, height: 1000),
                viewportSize: CGSize(width: 300, height: 200)
            ),
            follower: follower(offset: 0),
            axes: .vertical,
            from: .first
        )
        #expect(origin.y == CGFloat(200))
        #expect(origin.x == CGFloat(0))
    }

    @Test func horizontalSyncLeavesTheFollowerWhereItIsVertically() {
        let origin = ScrollSyncStrategy.absolute.followerOrigin(
            leader: ScrollPaneMetrics(
                offset: CGPoint(x: 120, y: 400),
                contentSize: CGSize(width: 900, height: 1000),
                viewportSize: CGSize(width: 300, height: 200)
            ),
            follower: ScrollPaneMetrics(
                offset: CGPoint(x: 0, y: 77),
                contentSize: CGSize(width: 900, height: 600),
                viewportSize: CGSize(width: 300, height: 200)
            ),
            axes: .horizontal,
            from: .first
        )
        #expect(origin.x == CGFloat(120))
        #expect(origin.y == CGFloat(77))
    }

    @Test func bothAxesMoveTogether() {
        let origin = ScrollSyncStrategy.absolute.followerOrigin(
            leader: ScrollPaneMetrics(
                offset: CGPoint(x: 120, y: 400),
                contentSize: CGSize(width: 900, height: 1000),
                viewportSize: CGSize(width: 300, height: 200)
            ),
            follower: ScrollPaneMetrics(
                offset: CGPoint(x: 0, y: 0),
                contentSize: CGSize(width: 900, height: 1000),
                viewportSize: CGSize(width: 300, height: 200)
            ),
            axes: .both,
            from: .first
        )
        #expect(origin.x == CGFloat(120))
        #expect(origin.y == CGFloat(400))
    }

    // MARK: - Echo filter

    /// `shouldRelay` is asked outside the `#expect` in every test below, and
    /// has to be: it mutates the filter, and the macro binds the pieces of
    /// its expression immutably so it can print them back on a failure.
    @Test func aReportNobodyAskedForIsTheReadersAndGetsRelayed() {
        var filter = ScrollEchoFilter()
        let relayed = filter.shouldRelay(CGPoint(x: 0, y: 300), from: .first)
        #expect(relayed)
    }

    @Test func theEchoOfOurOwnWriteIsSwallowed() {
        var filter = ScrollEchoFilter()
        filter.willApply(CGPoint(x: 0, y: 200), to: .second)
        let relayed = filter.shouldRelay(CGPoint(x: 0, y: 200), from: .second)
        #expect(!relayed)
    }

    /// A clip view snaps to the pixel grid, so the value that comes back is
    /// near the one that went in rather than equal to it. An echo filter
    /// that demanded equality would let every echo through on a Retina
    /// display and none on an integral one, which is the sort of bug that
    /// only shows up on someone else's machine.
    @Test func anEchoRoundedByTheClipViewIsStillAnEcho() {
        var filter = ScrollEchoFilter()
        filter.willApply(CGPoint(x: 0, y: 200), to: .second)
        let relayed = filter.shouldRelay(CGPoint(x: 0, y: 200.4), from: .second)
        #expect(!relayed)
    }

    @Test func aScrollFurtherThanTheRoundingIsTheReadersAgain() {
        var filter = ScrollEchoFilter()
        filter.willApply(CGPoint(x: 0, y: 200), to: .second)
        let relayed = filter.shouldRelay(CGPoint(x: 0, y: 260), from: .second)
        #expect(relayed)
    }

    /// One write suppresses one report and no more. Otherwise a pane the
    /// reader flicks back to where the link had put it would stay silent
    /// forever after.
    @Test func anExpectationIsSpentOnTheFirstReport() {
        var filter = ScrollEchoFilter()
        filter.willApply(CGPoint(x: 0, y: 200), to: .second)
        let firstReport = filter.shouldRelay(CGPoint(x: 0, y: 200), from: .second)
        let secondReport = filter.shouldRelay(CGPoint(x: 0, y: 200), from: .second)
        #expect(!firstReport)
        #expect(secondReport)
    }

    @Test func onePanesEchoDoesNotSilenceTheOther() {
        var filter = ScrollEchoFilter()
        filter.willApply(CGPoint(x: 0, y: 200), to: .second)
        let relayed = filter.shouldRelay(CGPoint(x: 0, y: 200), from: .first)
        #expect(relayed)
    }

    @Test func sidesPointAtEachOther() {
        #expect(ScrollSyncSide.first.other == .second)
        #expect(ScrollSyncSide.second.other == .first)
    }
}

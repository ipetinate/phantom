import CoreGraphics
import Foundation

/// Which of a split's two panes something refers to.
///
/// Named for position in the pair rather than for a role. The same pane is
/// the leader while the reader is scrolling it and the follower a moment
/// later, so a type that called one of them "leader" would be wrong half
/// the time.
enum ScrollSyncSide: Hashable {
    case first
    case second

    var other: ScrollSyncSide { self == .first ? .second : .first }
}

/// Which axes a link keeps in step.
///
/// Vertical alone is the usual answer. Horizontal earns its place in a
/// side-by-side diff, where the two panes hold the same long lines and
/// scrolling one sideways without the other puts different columns of the
/// same line beside each other.
struct ScrollSyncAxes: OptionSet {
    let rawValue: Int

    static let vertical = ScrollSyncAxes(rawValue: 1 << 0)
    static let horizontal = ScrollSyncAxes(rawValue: 1 << 1)
    static let both: ScrollSyncAxes = [.vertical, .horizontal]
}

/// What one scroll view is showing, read off it once so every decision made
/// from it is arithmetic on values — and therefore testable with no view,
/// no window and no run loop.
///
/// Offsets are measured from the top, which is what a clip view reports for
/// a **flipped** document view. Everything that scrolls in this app is
/// flipped: `NSTextView` is, and so is the content SwiftUI puts inside a
/// `ScrollView`. A non-flipped document view would synchronise upside down,
/// and the link does not carry that second convention because nothing here
/// needs it.
struct ScrollPaneMetrics: Equatable {
    var offset: CGPoint
    var contentSize: CGSize
    var viewportSize: CGSize
}

/// One axis of one sync decision: where the leader sits, and how much room
/// each pane has along that axis.
struct ScrollSyncGeometry: Equatable {
    var leaderOffset: CGFloat
    var leaderContentLength: CGFloat
    var leaderViewportLength: CGFloat
    var followerContentLength: CGFloat
    var followerViewportLength: CGFloat

    /// How far the leader can travel before it runs out of content.
    var leaderScrollableLength: CGFloat {
        max(0, leaderContentLength - leaderViewportLength)
    }

    var followerScrollableLength: CGFloat {
        max(0, followerContentLength - followerViewportLength)
    }

    /// The leader's position as a fraction of its own travel, 0…1.
    ///
    /// Zero when there is no travel: a pane short enough to fit its own
    /// viewport is showing the top of itself, and that is the honest answer
    /// to "how far down is it" rather than a division by zero.
    var leaderProgress: CGFloat {
        guard leaderScrollableLength > 0 else { return 0 }
        return min(1, max(0, leaderOffset / leaderScrollableLength))
    }
}

/// How far the follower goes when the leader moves.
///
/// A value wrapping a closure rather than an enum of cases, because the one
/// mapping that matters most cannot be written here. A diff knows which of
/// its rows correspond; a markdown preview knows where in the rendered
/// output a source line ended up. Neither fact is derivable from heights,
/// so the container takes the mapping as a parameter and supplies only the
/// two answers that *are* derivable.
struct ScrollSyncStrategy {
    private let map: (ScrollSyncGeometry) -> CGFloat

    init(_ map: @escaping (ScrollSyncGeometry) -> CGFloat) {
        self.map = map
    }

    /// The follower lands on the leader's own offset.
    ///
    /// The right answer when both panes are laid out on one grid and hold
    /// the same number of rows — which is what a side-by-side diff produces
    /// when it pads each side with fillers opposite the other side's
    /// inserted and deleted lines. Row *n* of one pane is then at the same y
    /// as row *n* of the other, so equal offsets *are* line-for-line
    /// alignment and nobody has to count lines to get it.
    static let absolute = ScrollSyncStrategy { $0.leaderOffset }

    /// The follower sits the same fraction into its own travel.
    ///
    /// For panes whose lengths have nothing to do with each other — raw
    /// markdown against its rendered form, where three backticks become a
    /// block and a link renders shorter than its source. There is no row *n*
    /// to match, so matching the ends is the most that is true: top with
    /// top, bottom with bottom, and a proportion in between.
    static let proportional = ScrollSyncStrategy {
        $0.leaderProgress * $0.followerScrollableLength
    }

    /// Where the follower should sit along one axis, clamped to what it can
    /// actually show.
    ///
    /// The clamp lives here rather than inside each mapping so that a host's
    /// own mapping cannot scroll a pane past its end into blank space, and
    /// so there is one place to look when it does.
    func followerOffset(for geometry: ScrollSyncGeometry) -> CGFloat {
        min(geometry.followerScrollableLength, max(0, map(geometry)))
    }

    /// Where the follower's clip view should go, for the axes being kept in
    /// step.
    ///
    /// An axis that is not synchronised keeps whatever the follower already
    /// had, so turning on vertical sync never nudges a pane sideways.
    func followerOrigin(
        leader: ScrollPaneMetrics,
        follower: ScrollPaneMetrics,
        axes: ScrollSyncAxes
    ) -> CGPoint {
        var origin = follower.offset

        if axes.contains(.vertical) {
            origin.y = followerOffset(for: ScrollSyncGeometry(
                leaderOffset: leader.offset.y,
                leaderContentLength: leader.contentSize.height,
                leaderViewportLength: leader.viewportSize.height,
                followerContentLength: follower.contentSize.height,
                followerViewportLength: follower.viewportSize.height
            ))
        }

        if axes.contains(.horizontal) {
            origin.x = followerOffset(for: ScrollSyncGeometry(
                leaderOffset: leader.offset.x,
                leaderContentLength: leader.contentSize.width,
                leaderViewportLength: leader.viewportSize.width,
                followerContentLength: follower.contentSize.width,
                followerViewportLength: follower.viewportSize.width
            ))
        }

        return origin
    }
}

extension ScrollSyncStrategy {
    /// Line-for-line alignment for two panes on the same row grid holding
    /// different numbers of rows.
    ///
    /// The caller supplies the only thing it can know: which of the *other*
    /// pane's rows a row of this one corresponds to. A diff that does not
    /// pad its two sides needs this — the lines removed from the left have
    /// no rows at all on the right, so line 40 of the old file may be line
    /// 31 of the new one, and no arithmetic over heights can discover that.
    ///
    /// Whatever fraction of a row the leader is scrolled by is carried over
    /// unchanged, so the follower moves smoothly with it instead of jumping
    /// a whole row at a time.
    static func rowAligned(
        rowHeight: CGFloat,
        followerRow: @escaping (Int) -> Int
    ) -> ScrollSyncStrategy {
        ScrollSyncStrategy { geometry in
            guard rowHeight > 0 else { return geometry.leaderOffset }
            let row = (geometry.leaderOffset / rowHeight).rounded(.down)
            let withinRow = geometry.leaderOffset - row * rowHeight
            return CGFloat(followerRow(Int(row))) * rowHeight + withinRow
        }
    }
}

/// Tells a scroll the reader performed apart from the echo of one the link
/// performed itself.
///
/// Without this the panes chase each other. A moves; B is moved to follow;
/// B's clip view reports a bounds change, which is indistinguishable from
/// the reader scrolling B; so A is moved to follow *that*. Under
/// `.absolute` the round trip happens to land back where it started and the
/// loop dies quietly, which is exactly why it is not a safe thing to leave
/// to luck — under `.proportional` with panes of different lengths it does
/// not land back, and the two drift a few points apart per hop until they
/// pin against the ends.
///
/// The filter remembers the origin it last handed to each side and refuses
/// to relay a report that matches it. Remembering the *value* rather than
/// raising a flag for the duration of the call is deliberate: a clip view
/// does not promise to post its bounds change synchronously, and a flag
/// lowered when `scroll(to:)` returns can already be down when a late echo
/// arrives. `ScrollSyncLink` keeps such a flag as well; the two cover each
/// other's blind spot, the flag catching a synchronous post and this
/// catching a late one.
struct ScrollEchoFilter {
    /// How far a reported origin may sit from the one that was written and
    /// still count as the same scroll. A clip view snaps its origin to the
    /// backing store's pixel grid, so what comes back is rarely the exact
    /// value that went in.
    static let tolerance: CGFloat = 0.5

    private var expected: [ScrollSyncSide: CGPoint] = [:]

    init() {}

    /// Records where a side is about to be put.
    mutating func willApply(_ origin: CGPoint, to side: ScrollSyncSide) {
        expected[side] = origin
    }

    /// Whether a reported origin is the reader's doing, and so should reach
    /// the other pane.
    ///
    /// The expectation is consumed either way. That bounds the damage of a
    /// record left behind when a write produced no report at all: it can
    /// swallow at most one later scroll, and only one that happens to land
    /// on the very offset its pane is already sitting at — which moves
    /// nothing regardless.
    mutating func shouldRelay(_ origin: CGPoint, from side: ScrollSyncSide) -> Bool {
        guard let pending = expected.removeValue(forKey: side) else { return true }
        return abs(pending.x - origin.x) > Self.tolerance
            || abs(pending.y - origin.y) > Self.tolerance
    }
}

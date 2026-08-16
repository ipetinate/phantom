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
/// ## Both directions, always
///
/// The mapping is told **which side is leading**, because one strategy value
/// serves both directions and the two directions are not always the same
/// function.
///
/// A padded diff hides this: with both sides on one grid, `.absolute` really
/// is symmetric, so a map that ignored the side would be correct by
/// accident. Raw markdown against its rendered form is where it breaks.
/// Source line 12 landing at rendered y=400 does not mean rendered y=400
/// came from source line 12 — the relation is not even injective, since a
/// fenced block is many source lines at one rendered offset. Handed only a
/// source→rendered map, the link would apply that very map to the
/// *preview's* offset the moment a reader scrolled the preview, and push a
/// meaningless number back into the source. Worse than `.proportional`,
/// which is at least wrong symmetrically.
struct ScrollSyncStrategy {
    private let map: (ScrollSyncGeometry, ScrollSyncSide) -> CGFloat

    /// - Parameter map: Where the follower goes, given the geometry and
    ///   which side is currently leading. A symmetric mapping is free to
    ///   ignore the second argument; an asymmetric one must branch on it.
    init(_ map: @escaping (ScrollSyncGeometry, ScrollSyncSide) -> CGFloat) {
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
    ///
    /// Symmetric, so the leading side changes nothing.
    static let absolute = ScrollSyncStrategy { geometry, _ in geometry.leaderOffset }

    /// The follower sits the same fraction into its own travel.
    ///
    /// For panes whose lengths have nothing to do with each other — raw
    /// markdown against its rendered form, where three backticks become a
    /// block and a link renders shorter than its source. There is no row *n*
    /// to match, so matching the ends is the most that is true: top with
    /// top, bottom with bottom, and a proportion in between.
    /// Symmetric in the sense that matters: whichever side leads, the
    /// answer is that side's progress applied to the other's travel.
    static let proportional = ScrollSyncStrategy { geometry, _ in
        geometry.leaderProgress * geometry.followerScrollableLength
    }

    /// Where the follower should sit along one axis, clamped to what it can
    /// actually show.
    ///
    /// The clamp lives here rather than inside each mapping so that a host's
    /// own mapping cannot scroll a pane past its end into blank space, and
    /// so there is one place to look when it does.
    /// - Parameter side: Which side is leading, passed through to the
    ///   mapping so an asymmetric one can pick the right direction.
    func followerOffset(
        for geometry: ScrollSyncGeometry,
        from side: ScrollSyncSide
    ) -> CGFloat {
        min(geometry.followerScrollableLength, max(0, map(geometry, side)))
    }

    /// Where the follower's clip view should go, for the axes being kept in
    /// step.
    ///
    /// An axis that is not synchronised keeps whatever the follower already
    /// had, so turning on vertical sync never nudges a pane sideways.
    func followerOrigin(
        leader: ScrollPaneMetrics,
        follower: ScrollPaneMetrics,
        axes: ScrollSyncAxes,
        from side: ScrollSyncSide
    ) -> CGPoint {
        var origin = follower.offset

        if axes.contains(.vertical) {
            origin.y = followerOffset(
                for: ScrollSyncGeometry(
                    leaderOffset: leader.offset.y,
                    leaderContentLength: leader.contentSize.height,
                    leaderViewportLength: leader.viewportSize.height,
                    followerContentLength: follower.contentSize.height,
                    followerViewportLength: follower.viewportSize.height
                ),
                from: side
            )
        }

        if axes.contains(.horizontal) {
            origin.x = followerOffset(
                for: ScrollSyncGeometry(
                    leaderOffset: leader.offset.x,
                    leaderContentLength: leader.contentSize.width,
                    leaderViewportLength: leader.viewportSize.width,
                    followerContentLength: follower.contentSize.width,
                    followerViewportLength: follower.viewportSize.width
                ),
                from: side
            )
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
    /// **Both directions are required, and that is not ceremony.** An
    /// alignment between two unpadded files is not symmetric: old→new and
    /// new→old are different functions, and neither is the other's inverse
    /// wherever a run of lines was deleted or inserted, because several rows
    /// on one side collapse onto one row of the other. A single closure
    /// would be applied to whichever pane the reader happened to scroll, and
    /// would be right only half the time — silently, and only in files that
    /// actually have deletions.
    ///
    /// Whatever fraction of a row the leader is scrolled by is carried over
    /// unchanged, so the follower moves smoothly with it instead of jumping
    /// a whole row at a time.
    ///
    /// - Parameters:
    ///   - firstToSecond: Given a row of the pane attached as `.first`, the
    ///     row of `.second` beside it.
    ///   - secondToFirst: The same journey the other way. Derive it from the
    ///     same alignment table rather than by inverting the closure above,
    ///     which cannot be inverted.
    static func rowAligned(
        rowHeight: CGFloat,
        firstToSecond: @escaping (Int) -> Int,
        secondToFirst: @escaping (Int) -> Int
    ) -> ScrollSyncStrategy {
        ScrollSyncStrategy { geometry, side in
            guard rowHeight > 0 else { return geometry.leaderOffset }
            let row = (geometry.leaderOffset / rowHeight).rounded(.down)
            let withinRow = geometry.leaderOffset - row * rowHeight
            let followerRow = side == .first ? firstToSecond(Int(row)) : secondToFirst(Int(row))
            return CGFloat(followerRow) * rowHeight + withinRow
        }
    }
}

/// Tells a scroll the reader performed apart from the echo of one the link
/// performed itself.
///
/// Without this the panes chase each other. A moves; B is moved to follow;
/// B's clip view reports a bounds change, which is indistinguishable from
/// the reader scrolling B; so A is moved to follow *that*.
///
/// **How badly that ends depends entirely on the strategy, and the worst
/// case is now the ordinary one.** Three tiers, and do not read the first
/// as the general behaviour:
///
/// - `.absolute`'s round trip is the identity, so a leaked echo lands back
///   where it started and the loop dies quietly. That is luck, not design —
///   a property of that one mapping.
/// - `.proportional` between panes of different lengths does not land back,
///   and the two drift a few points apart per hop until they pin against
///   the ends.
/// - **An asymmetric mapping has no such property at all.** Raw markdown
///   against its rendered form is two unrelated functions, and nothing
///   brings a round trip home: a single unfiltered echo does not drift, it
///   walks both panes to their ends in one go.
///
/// So this is not a defensive optimisation and must not be simplified into
/// one. For a symmetric strategy it is insurance; for an asymmetric one it
/// is the only thing standing between the reader and two pinned panes.
/// `ScrollSyncLinkTests.anAsymmetricStrategysEchoIsStillSwallowed` keeps a
/// deliberately pathological mapping — one adding a hundred points in
/// *both* directions — so that removing this fails loudly there rather than
/// only on somebody's README.
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

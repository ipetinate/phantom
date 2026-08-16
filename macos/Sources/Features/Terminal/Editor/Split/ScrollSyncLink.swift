import AppKit
import Combine
import SwiftUI

/// Keeps two scroll views in step.
///
/// Built on the mechanism the gutter and the minimap already use — a clip
/// view with `postsBoundsChangedNotifications` set, observed for
/// `NSView.boundsDidChangeNotification`. That notification is the only thing
/// that reports *every* way a scroll view moves: the wheel, a trackpad
/// flick and its momentum, a scroller drag, a keyboard page, and
/// `scrollRangeToVisible` when something reveals a match. Watching the
/// scroller or the wheel would catch some of those and miss the rest.
///
/// The link holds its scroll views weakly and is told about them rather
/// than going looking, so it works the same for a pane that builds its own
/// `NSScrollView` and one that gets SwiftUI's.
///
/// An `NSObject` because `NotificationCenter`'s target-and-selector
/// registration is the only form that can be unregistered for one object
/// without holding a token per observation, and `@objc` needs a class the
/// Objective-C runtime can see.
@MainActor
final class ScrollSyncLink: NSObject, ObservableObject {
    /// Whether scrolling one pane moves the other.
    ///
    /// Off unless a host asks for it. A link that synchronised by existing
    /// would make the decision for both features that share this container,
    /// and reading a wide diff one side at a time is a perfectly good reason
    /// to leave it off.
    @Published var isEnabled: Bool

    /// How far the follower goes. Settable after the fact because a host
    /// often only learns which mapping applies once it has parsed its own
    /// content — a diff cannot pick between row alignment and proportion
    /// until it knows whether its two sides came out the same length.
    var strategy: ScrollSyncStrategy

    var axes: ScrollSyncAxes

    private weak var firstScrollView: NSScrollView?
    private weak var secondScrollView: NSScrollView?

    private var echo = ScrollEchoFilter()

    /// Raised for the length of one relay, so a clip view that posts its
    /// bounds change synchronously — inside the `scroll(to:)` below — finds
    /// the door shut. See `ScrollEchoFilter` for why this is not the whole
    /// answer on its own.
    private var isRelaying = false

    init(
        strategy: ScrollSyncStrategy = .proportional,
        axes: ScrollSyncAxes = .vertical,
        isEnabled: Bool = false
    ) {
        self.strategy = strategy
        self.axes = axes
        self.isEnabled = isEnabled
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Puts a scroll view on one side of the link, replacing whatever was
    /// there.
    ///
    /// Call it from `makeNSView` for a pane that builds its own scroll view.
    /// Calling it again with the same view is free, which matters because
    /// `updateNSView` runs far more often than anything changes.
    func attach(_ scrollView: NSScrollView, as side: ScrollSyncSide) {
        guard self.scrollView(for: side) !== scrollView else { return }
        detach(side)

        switch side {
        case .first: firstScrollView = scrollView
        case .second: secondScrollView = scrollView
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    /// Takes a side out of the link. The other side keeps working and
    /// simply has nothing to move.
    func detach(_ side: ScrollSyncSide) {
        guard let scrollView = self.scrollView(for: side) else { return }

        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        switch side {
        case .first: firstScrollView = nil
        case .second: secondScrollView = nil
        }
    }

    /// What a side is attached to, or nil.
    func scrollView(for side: ScrollSyncSide) -> NSScrollView? {
        switch side {
        case .first: return firstScrollView
        case .second: return secondScrollView
        }
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else { return }

        if clipView === firstScrollView?.contentView {
            relay(from: .first)
        } else if clipView === secondScrollView?.contentView {
            relay(from: .second)
        }
    }

    /// Moves the other pane to match this one, if this report was the
    /// reader's doing rather than the link's.
    ///
    /// Internal rather than private so a test can drive a relay without
    /// depending on when AppKit chooses to post a bounds change.
    func relay(from side: ScrollSyncSide) {
        guard isEnabled, !isRelaying else { return }
        guard let leader = scrollView(for: side),
              let follower = scrollView(for: side.other)
        else { return }

        let leaderMetrics = Self.metrics(of: leader)
        guard echo.shouldRelay(leaderMetrics.offset, from: side) else { return }

        let followerMetrics = Self.metrics(of: follower)
        let target = strategy.followerOrigin(
            leader: leaderMetrics,
            follower: followerMetrics,
            axes: axes
        )

        /// A pane already sitting where it is being sent posts nothing,
        /// which would leave the record below waiting for a report that
        /// never comes. Cheaper as well: most relays during a slow scroll
        /// land on the offset the follower is already at.
        guard abs(target.x - followerMetrics.offset.x) > ScrollEchoFilter.tolerance
            || abs(target.y - followerMetrics.offset.y) > ScrollEchoFilter.tolerance
        else { return }

        isRelaying = true
        echo.willApply(target, to: side.other)
        follower.contentView.scroll(to: target)
        follower.reflectScrolledClipView(follower.contentView)
        isRelaying = false
    }

    /// Reads a scroll view down to the numbers the arithmetic needs, so
    /// that arithmetic never has to hold a view.
    static func metrics(of scrollView: NSScrollView) -> ScrollPaneMetrics {
        ScrollPaneMetrics(
            offset: scrollView.contentView.bounds.origin,
            contentSize: scrollView.documentView?.frame.size ?? .zero,
            viewportSize: scrollView.contentView.bounds.size
        )
    }
}

extension View {
    /// Hands the enclosing scroll view to a link.
    ///
    /// For panes built out of SwiftUI, where nothing in the host's own code
    /// ever holds the `NSScrollView`. Apply it to the content **inside** a
    /// `ScrollView`: the probe finds its scroll view by looking outwards, so
    /// applied to the `ScrollView` itself it would look straight past it and
    /// find whatever is scrolling further up the window, or nothing.
    ///
    /// A pane that builds its own scroll view should call
    /// `ScrollSyncLink.attach(_:as:)` from `makeNSView` instead — exact, and
    /// with nothing to search for.
    func synchronizedScroll(_ link: ScrollSyncLink, as side: ScrollSyncSide) -> some View {
        background(ScrollSyncProbe(link: link, side: side).frame(width: 0, height: 0))
    }
}

/// A view with no size and nothing to draw, whose entire job is to be
/// inside a scroll view and say which one.
private struct ScrollSyncProbe: NSViewRepresentable {
    let link: ScrollSyncLink
    let side: ScrollSyncSide

    func makeNSView(context: Context) -> ScrollSyncProbeView {
        let view = ScrollSyncProbeView()
        view.onAttach = { [link, side] scrollView in link.attach(scrollView, as: side) }
        view.onDetach = { [link, side] in link.detach(side) }
        return view
    }

    /// Re-checked on every update rather than resolved once. `makeNSView`
    /// runs before the view is in a hierarchy, so there is nothing to find
    /// at that point; and a pane whose content is swapped can end up in a
    /// different scroll view than the one it started in.
    func updateNSView(_ view: ScrollSyncProbeView, context: Context) {
        view.attachToEnclosingScrollView()
    }
}

/// Internal rather than private so a test can put one inside a real scroll
/// view and check that it finds it. The searching is the whole mechanism of
/// the SwiftUI path, and it is the half that cannot be checked by looking
/// at the code.
final class ScrollSyncProbeView: NSView {
    var onAttach: ((NSScrollView) -> Void)?
    var onDetach: (() -> Void)?

    private weak var attached: NSScrollView?

    /// Never takes a click. `.background` puts this behind the pane's
    /// content, so the content answers first — but only where the content
    /// is there to answer, and a rendered document is mostly gaps. Without
    /// this, selecting text by dragging through a blank line would begin on
    /// the probe instead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        guard superview != nil else {
            guard attached != nil else { return }
            attached = nil
            onDetach?()
            return
        }

        attachToEnclosingScrollView()
    }

    func attachToEnclosingScrollView() {
        guard let scrollView = enclosingScrollView, scrollView !== attached else { return }
        attached = scrollView
        onAttach?(scrollView)
    }
}

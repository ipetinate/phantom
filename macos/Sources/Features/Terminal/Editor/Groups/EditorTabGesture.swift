import CoreGraphics
import Foundation

/// What a drag on a tab turns into: nothing yet, a move along the strip, or
/// the split drag leaving it.
///
/// Every tab drag used to be the split drag. There was no way to reorder a
/// tab, and no distance to clear first, so a click that moved a point on the
/// way down opened the drop panel over the pane. Both faults are one missing
/// decision, and this is it.
///
/// A value with no view in it, so the decision can be tested without a
/// window — see `EditorTabGestureTests`. The AppKit half that feeds it is
/// `EditorTabDragSource.DragSourceView`, which does no arithmetic of its own.
struct EditorTabGesture {
    /// Which way the tab is being pulled.
    enum Axis: Equatable {
        /// Along the strip. The tab changes places with its neighbours, and
        /// no drag session is ever begun.
        case along

        /// Out of the strip, up or down. The tab leaves the row and the split
        /// drag takes over.
        case out
    }

    /// What to do about the pointer's latest position.
    enum Step: Equatable {
        case idle

        /// Move the tab this many places along the strip. Negative is left.
        case reorder(Int)

        /// Begin the split drag. Reported once per gesture.
        case detach
    }

    /// How far the pointer must travel before the gesture is anything at all.
    ///
    /// A click's own jitter is one to two points — the hand moving while the
    /// button goes down — and until now nothing stood between that and a drag
    /// session, which is the "it starts dragging when I meant to click"
    /// report. Five points clears the jitter and is still well under the
    /// fifteen or twenty the first frames of a deliberate drag cover, so a
    /// drag the reader means still starts on the first move they make.
    static let activation: CGFloat = 5

    /// How far up or down the tab must go before the split drag begins.
    ///
    /// Half the tab's height, so this fires once the pointer has left the
    /// tab's own row rather than merely wobbled inside it. The reader
    /// described the gesture as pulling the tab out of its place, which is a
    /// distance and not only a direction — and it is the expensive half of
    /// the gesture, because a split divides the pane and has to be undone by
    /// hand, while a reorder is undone by dragging back.
    static let detachDistance: CGFloat = EditorTabBar.tabHeight / 2

    /// The shortest a step along the strip may be.
    ///
    /// A step is the dragged tab's own width. A tab holding a short name is
    /// narrow enough that half of it is a few points, and the row would
    /// shuffle under a hand that had barely moved. Forty-four points is an
    /// icon and about three characters, which is the narrowest tab the bar
    /// draws.
    static let minimumStep: CGFloat = 44

    /// How wide one place along the strip is.
    private let step: CGFloat

    /// The axis, once it is known. Nil until the pointer clears `activation`.
    ///
    /// Decided once and then held for the rest of the gesture, deliberately.
    /// Deciding it again on every event reads the direction of the *last few
    /// points* rather than the reader's intent, and every hand curves: a
    /// movement that is mostly sideways crosses the diagonal several times on
    /// its way, so the tab would flip between reordering and detaching while
    /// the reader was still aiming.
    private(set) var axis: Axis?

    /// How many places the tab has actually moved so far.
    ///
    /// Advanced by `moved` rather than by `update`, because the strip is
    /// allowed to refuse: `EditorTabSet.move` will not carry a tab across the
    /// pinned boundary or off the end of its run. Counting what was asked for
    /// instead of what happened would leave this ahead of the strip, and
    /// dragging back to where the gesture began would then move a tab that had
    /// never moved.
    private var placed = 0

    /// Set once `detach` has been reported, so one gesture begins one session.
    private var hasDetached = false

    /// - Parameter tabWidth: how wide the dragged tab is, floored at
    ///   `minimumStep`.
    init(tabWidth: CGFloat) {
        step = max(tabWidth, Self.minimumStep)
    }

    /// - Parameter translation: how far the pointer has moved since the button
    ///   went down. Measured from the button rather than from the previous
    ///   event, so a slow drag cannot creep past the threshold one point at a
    ///   time and a gesture that comes back to its origin is back at zero.
    mutating func update(_ translation: CGSize) -> Step {
        guard !hasDetached else { return .idle }

        guard let axis = axis ?? Self.axis(for: translation) else { return .idle }
        self.axis = axis

        switch axis {
        case .out:
            guard abs(translation.height) >= Self.detachDistance else { return .idle }
            hasDetached = true
            return .detach

        case .along:
            let wanted = places(for: translation.width)
            guard wanted != placed else { return .idle }
            return .reorder(wanted - placed)
        }
    }

    /// What the strip did with the last `reorder`, which is not always what
    /// was asked of it — see `placed`.
    mutating func moved(_ places: Int) {
        placed += places
    }

    /// The axis a movement names, or nil while it is still too small to name
    /// one.
    ///
    /// The tie goes to `along`. A movement exactly on the diagonal reorders,
    /// because that is the half of the gesture the reader can undo by dragging
    /// back.
    private static func axis(for translation: CGSize) -> Axis? {
        guard hypot(translation.width, translation.height) >= activation else { return nil }
        return abs(translation.height) > abs(translation.width) ? .out : .along
    }

    /// How many places along the strip a sideways travel amounts to.
    ///
    /// Rounded, so the swap lands at half a tab's width: the point where the
    /// dragged tab covers more of its neighbour's place than of its own, which
    /// is where every strip with this gesture swaps.
    private func places(for width: CGFloat) -> Int {
        Int((width / step).rounded())
    }
}

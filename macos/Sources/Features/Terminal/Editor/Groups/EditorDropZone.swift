import CoreGraphics

/// Where a dragged tab would land, over one cell of the grid.
///
/// Five outcomes, decided by a point in a rectangle and nothing else. The
/// centre means "move the tab into this cell"; an edge means "split this
/// cell and put it on that side". The highlight the reader sees while
/// dragging is this same answer, drawn — so the geometry being right here is
/// the feedback being right, and a wrong answer is a layout they did not ask
/// for.
enum EditorDropZone: Equatable {
    case center
    case leading
    case trailing
    case top
    case bottom
}

extension EditorDropZone {
    /// How much of the cell, along each axis, an edge band claims.
    ///
    /// Half, which is as much as there is: the four edges then cover the
    /// whole surface and the boundaries between them are the cell's
    /// diagonals. The smallest target is a quarter of the cell.
    ///
    /// A quarter of each axis was the first try, then a third. Both were
    /// measured too fine in use, and the reason is that they made the reader
    /// aim at a *border*: the answer they wanted lived in a strip near an
    /// edge, and the middle of the cell — the easiest place to reach — did
    /// something else. An undivided cell has exactly two useful answers, side
    /// by side or stacked, so the surface may as well spend all of itself
    /// saying which.
    ///
    /// What this costs is the centre: with no band left over, "move the tab
    /// into this cell" cannot live in the surface. It lives on the tab bar,
    /// which `resolve` treats as a join — a wide, obvious target, and the
    /// same convention as the editors this gesture is borrowed from.
    static let defaultEdgeFraction: CGFloat = 0.5

    /// How much further a zone keeps its claim once it already holds it.
    ///
    /// Without this the answer flips as the pointer travels along a
    /// boundary — split, move, split — and the panel flickers under the
    /// cursor while the reader is trying to aim at it. A zone that is already
    /// chosen holds on for a little past its own edge, so crossing a boundary
    /// takes a deliberate movement rather than a tremor.
    static let hysteresis: CGFloat = 0.05

    /// The zone a point falls in, over a cell whose bar is `barHeight` tall.
    ///
    /// The bar is a join, never a split. That is the convention every editor
    /// with this gesture uses, and here it is also what makes the gesture
    /// *reversible*: a drag starts on a tab, so it starts at the top of a
    /// cell, and dragging it straight across to another cell arrives at the
    /// top of that one. With the bar resolving like any other top edge, the
    /// most natural gesture in the feature — take this tab back — split the
    /// grid into rows instead of merging it, every time.
    static func resolve(
        point: CGPoint,
        in size: CGSize,
        barHeight: CGFloat,
        current: EditorDropZone? = nil,
        edgeFraction: CGFloat = defaultEdgeFraction
    ) -> EditorDropZone {
        guard barHeight > 0 else {
            return resolve(
                point: point, in: size, current: current, edgeFraction: edgeFraction)
        }
        guard point.y > barHeight else { return .center }

        let surface = CGSize(width: size.width, height: size.height - barHeight)
        let local = CGPoint(x: point.x, y: point.y - barHeight)
        return resolve(
            point: local, in: surface, current: current, edgeFraction: edgeFraction)
    }

    /// The zone a point falls in.
    ///
    /// `point` is in the cell's own coordinates **with y increasing
    /// downward**, which is what SwiftUI reports to a drop callback. An
    /// AppKit caller over an unflipped view flips first; taking a flag
    /// instead would move the question to every call site rather than
    /// settling it in the one place that knows the answer.
    ///
    /// A corner resolves to the nearer edge rather than to a diagonal of its
    /// own: four edges are what a split can express, and a fifth answer
    /// there would be a coin toss wearing a rule.
    ///
    /// At the default claim the four edges tile the whole surface, so this
    /// returns `.center` only for a degenerate size. A point exactly on a
    /// diagonal is a tie, and ties go to the first of `leading`, `trailing`,
    /// `top`, `bottom` — an arbitrary order for a set of measure zero, named
    /// here so it is a decision rather than an accident.
    static func resolve(
        point: CGPoint,
        in size: CGSize,
        current: EditorDropZone? = nil,
        edgeFraction: CGFloat = defaultEdgeFraction
    ) -> EditorDropZone {
        guard size.width > 0, size.height > 0 else { return .center }

        let horizontal = min(max(point.x / size.width, 0), 1)
        let vertical = min(max(point.y / size.height, 0), 1)

        let distances: [(zone: EditorDropZone, distance: CGFloat)] = [
            (.leading, horizontal),
            (.trailing, 1 - horizontal),
            (.top, vertical),
            (.bottom, 1 - vertical),
        ]

        /// The zone in hand is scored as if it were nearer than it is, so it
        /// wins against a rival that has only just overtaken it. Applied to
        /// the *comparison* rather than to the band: at the default claim
        /// every point is inside some band, so a margin on the band alone
        /// would decide nothing and the panel would stutter between two
        /// answers whenever the pointer travelled along a diagonal.
        let scored = distances.map { candidate in
            (
                zone: candidate.zone,
                distance: candidate.distance,
                score: candidate.zone == current
                    ? candidate.distance - hysteresis
                    : candidate.distance
            )
        }

        guard let nearest = scored.min(by: { $0.score < $1.score }) else {
            return .center
        }

        /// And it also holds a little past its own edge, which is what keeps
        /// a narrowed band — `edgeFraction` below the default — from flipping
        /// to the centre on a tremor.
        let claim = nearest.zone == current ? edgeFraction + hysteresis : edgeFraction
        return nearest.distance <= claim ? nearest.zone : .center
    }

    /// The split this zone asks for: which way to divide the cell, and
    /// whether the arriving tab takes the first half. Nil for the centre,
    /// which asks for no split at all.
    var split: (direction: SplitViewDirection, onFirstSide: Bool)? {
        switch self {
        case .center: return nil
        case .leading: return (.horizontal, true)
        case .trailing: return (.horizontal, false)
        case .top: return (.vertical, true)
        case .bottom: return (.vertical, false)
        }
    }
}

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
    /// A quarter: wide enough to hit without aiming on a small cell, narrow
    /// enough that the middle half of a cell still means "move it here".
    static let defaultEdgeFraction: CGFloat = 0.25

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
        edgeFraction: CGFloat = defaultEdgeFraction
    ) -> EditorDropZone {
        guard barHeight > 0 else {
            return resolve(point: point, in: size, edgeFraction: edgeFraction)
        }
        guard point.y > barHeight else { return .center }

        let surface = CGSize(width: size.width, height: size.height - barHeight)
        let local = CGPoint(x: point.x, y: point.y - barHeight)
        return resolve(point: local, in: surface, edgeFraction: edgeFraction)
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
    static func resolve(
        point: CGPoint,
        in size: CGSize,
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

        guard let nearest = distances.min(by: { $0.distance < $1.distance }) else {
            return .center
        }
        return nearest.distance <= edgeFraction ? nearest.zone : .center
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

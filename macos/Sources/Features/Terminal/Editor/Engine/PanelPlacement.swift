import AppKit

/// Where a floating panel goes relative to the line it is about.
///
/// Extracted from `CodeHoverPanel`, where it was private and therefore
/// untested, because the completion list needs the same flip-and-clamp and
/// wants the opposite preference. Sharing **only** the geometry is deliberate:
/// the two panels are otherwise nothing alike — the hover card may take key
/// status on demand and the completion list must never take it, since clicking a
/// row would stop the caret blinking and leave the list unnavigable in the same
/// gesture that opened it.
///
/// Pure, and free of both windows and screens: it takes the visible rectangle as
/// a value, which is what lets a test place a panel near the top of a display
/// without owning one.
struct PanelPlacement {
    /// Which side of the anchor the panel would rather be on.
    enum Edge: Equatable, Sendable {
        case above
        case below
    }

    /// The breathing room between the anchor line and the panel.
    static let gap: CGFloat = 6

    /// How close to the edge of the display the panel is allowed to sit.
    static let margin: CGFloat = 8

    /// The panel's bottom-left corner, in the same coordinate space as `anchor`
    /// and `visible` — screen coordinates in practice, so y grows upwards and
    /// "above" means a larger y.
    ///
    /// The preference is a real preference and not a hint: it flips to the other
    /// side only when the preferred one does not fit, and if neither side fits it
    /// stays on the preferred one and lets the clamp decide what gets cut off.
    /// That last part is the subtle one — a panel taller than the space available
    /// has to lose its *end*, not its beginning, because the beginning is the
    /// part being read.
    ///
    /// The hover card prefers `.above`, because the code you are reading
    /// continues downwards: a card below the line covers what comes next, which
    /// is usually the thing being explained. The completion list prefers
    /// `.below`, because there the caret's own line is what must stay visible —
    /// you are watching the prefix you are typing, not the line under it.
    static func origin(anchor: NSRect, size: NSSize, visible: NSRect, prefers: Edge) -> NSPoint {
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - size.height

        var origin = NSPoint(x: anchor.minX, y: prefers == .above ? above : below)

        switch prefers {
        case .above:
            if origin.y + size.height > visible.maxY, below >= visible.minY {
                origin.y = below
            }
        case .below:
            if origin.y < visible.minY, above + size.height <= visible.maxY {
                origin.y = above
            }
        }

        origin.x = min(
            max(origin.x, visible.minX + margin),
            max(visible.maxX - size.width - margin, visible.minX)
        )
        origin.y = min(
            max(origin.y, visible.minY + margin),
            max(visible.maxY - size.height - margin, visible.minY)
        )
        return origin
    }
}

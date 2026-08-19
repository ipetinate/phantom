import AppKit
@testable import Ghostty
import Testing

/// Where a floating panel lands relative to the line it is about.
///
/// This was private inside `CodeHoverPanel` and therefore untested; the hover
/// card has been flipping and clamping itself on real displays with nothing
/// pinning the behaviour down. Extracting it so the completion list could share
/// it is what gave it these.
///
/// Nothing here touches a window. That is the point of taking the visible
/// rectangle as a value: a test can put a panel at the top of a display without
/// owning one, and `NSWindow.isVisible` only becomes true by asking the window
/// server to show something — which from a test host with no `NSApplication`
/// event loop hangs the call forever instead of returning.
struct PanelPlacementTests {
    private let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = NSSize(width: 200, height: 100)

    private func origin(
        anchorX: CGFloat = 100,
        anchorY: CGFloat,
        anchorHeight: CGFloat = 16,
        size: NSSize? = nil,
        visible: NSRect? = nil,
        prefers: PanelPlacement.Edge
    ) -> NSPoint {
        PanelPlacement.origin(
            anchor: NSRect(x: anchorX, y: anchorY, width: 50, height: anchorHeight),
            size: size ?? self.size,
            visible: visible ?? self.visible,
            prefers: prefers
        )
    }

    // MARK: - The preference

    /// `.above` is nobody's preference now that the hover card has been
    /// flipped to below, and it is still a real one: it is the side both
    /// panels flip to when the display's edge is in the way, so it has to
    /// keep meaning what it says.
    @Test func abovePutsThePanelOverTheAnchor() {
        let point = origin(anchorY: 400, prefers: .above)

        #expect(point.y == 400 + 16 + PanelPlacement.gap)
        #expect(point.x == 100)
    }

    /// What both panels ask for. The completion list because it is the caret's
    /// own line that has to stay visible — you are watching the prefix you are
    /// typing, not the line under it — and the hover card because a card above
    /// the line stands between the pointer and the word it describes.
    @Test func belowPutsThePanelUnderTheAnchor() {
        let point = origin(anchorY: 400, prefers: .below)

        #expect(point.y == 400 - PanelPlacement.gap - size.height)
    }

    // MARK: - The flip

    @Test func aPanelWithNoRoomAboveFlipsBelow() {
        let point = origin(anchorY: 750, prefers: .above)

        #expect(point.y == 750 - PanelPlacement.gap - size.height)
    }

    @Test func aPanelWithNoRoomBelowFlipsAbove() {
        let point = origin(anchorY: 20, prefers: .below)

        #expect(point.y == 20 + 16 + PanelPlacement.gap)
    }

    /// The subtle one. A panel taller than the space either side of the anchor
    /// stays on its preferred side and lets the clamp decide what gets cut —
    /// which has to be the *end*, because the beginning is the part being read.
    /// Flipping here would put the card's first line off the bottom of the
    /// screen, which is the failure mode the original comment describes.
    @Test func aPanelThatFitsNeitherSideKeepsItsPreferenceAndIsClamped() {
        let tall = NSSize(width: 200, height: 700)
        let point = origin(anchorY: 400, size: tall, prefers: .above)

        #expect(point.y == visible.maxY - tall.height - PanelPlacement.margin)
        #expect(point.y + tall.height <= visible.maxY, "the top of the panel must stay on screen")
    }

    // MARK: - The clamp

    @Test func aPanelIsPulledBackFromTheRightEdge() {
        let point = origin(anchorX: 980, anchorY: 400, prefers: .below)

        #expect(point.x == visible.maxX - size.width - PanelPlacement.margin)
    }

    @Test func aPanelIsPushedInFromTheLeftEdge() {
        let point = origin(anchorX: -50, anchorY: 400, prefers: .below)

        #expect(point.x == visible.minX + PanelPlacement.margin)
    }

    /// Defensive, and it has a real cause: a very narrow window on a very small
    /// display. Both clamp bounds cross over, and the answer has to be the
    /// display's own edge rather than a negative coordinate from a `max` applied
    /// in the wrong order.
    @Test func aPanelWiderThanTheDisplayIsPinnedToItsEdge() {
        let cramped = NSRect(x: 0, y: 0, width: 150, height: 50)
        let point = origin(
            anchorX: 10,
            anchorY: 10,
            anchorHeight: 5,
            visible: cramped,
            prefers: .below
        )

        #expect(point.x == cramped.minX)
        #expect(point.y == cramped.minY)
    }

    /// The visible frame is not rooted at zero on a Mac with a menu bar, or on a
    /// second display placed left of the first — so a panel must be clamped to
    /// *that* rectangle rather than to the origin.
    @Test func theClampFollowsADisplayThatDoesNotStartAtZero() {
        let secondary = NSRect(x: -1440, y: 100, width: 1440, height: 900)
        let point = origin(
            anchorX: -1430,
            anchorY: 110,
            visible: secondary,
            prefers: .below
        )

        #expect(point.x >= secondary.minX + PanelPlacement.margin)
        #expect(point.y >= secondary.minY + PanelPlacement.margin)
    }
}

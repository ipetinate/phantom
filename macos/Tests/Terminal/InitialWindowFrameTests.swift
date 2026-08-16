import AppKit
@testable import Ghostty
import Testing

/// Where a freshly created window opens.
///
/// A static over values, so the arithmetic is checkable without a window or a
/// screen — which is the only way any of this gets a test at all.
@MainActor
struct InitialWindowFrameTests {
    /// A 16" laptop with the menu bar already excluded.
    private let laptop = NSRect(x: 0, y: 0, width: 1728, height: 1050)

    /// An external display, where the preferred size fits with room to spare.
    private let external = NSRect(x: 0, y: 0, width: 3008, height: 1692)

    private func frame(
        sidebar: CGFloat = 260,
        visible: NSRect? = nil,
        preferred: NSSize = NSSize(width: 1280, height: 820)
    ) -> NSRect {
        TerminalController.initialFrame(
            sidebarWidth: sidebar,
            visible: visible ?? laptop,
            preferred: preferred
        )
    }

    @Test func theWindowIsCentredOnTheVisibleFrame() {
        let result = frame()
        #expect(result.midX == laptop.midX)
        #expect(result.midY == laptop.midY)
    }

    /// Centred on the screen it is *on*, not on one whose origin is zero —
    /// an external display sits at a non-zero origin in the global coordinate
    /// space, and centring on the size alone puts the window on the wrong
    /// monitor.
    @Test func centringFollowsTheScreensOrigin() {
        let secondary = NSRect(x: 1728, y: 240, width: 1920, height: 1080)
        let result = frame(visible: secondary)
        #expect(result.midX == secondary.midX)
        #expect(result.midY == secondary.midY)
    }

    /// The point of the whole change: the sidebar cannot end up squeezing the
    /// terminal beside it, because the window is sized for both.
    @Test func theWindowIsAlwaysWideEnoughForTheSidebarAndATerminal() {
        for sidebar in [CGFloat(180), 260, 420, 700] {
            let result = frame(sidebar: sidebar, visible: external)
            #expect(
                result.width >= sidebar + TerminalController.minimumTerminalWidth,
                "sidebar \(sidebar) left \(result.width - sidebar) for the terminal"
            )
        }
    }

    /// A sidebar dragged wider pushes the window wider rather than eating the
    /// terminal — the floor is the *current* width, not a constant.
    @Test func aWiderSidebarWidensTheWindow() {
        let narrow = frame(sidebar: 260, visible: external)
        let wide = frame(sidebar: 900, visible: external)
        #expect(wide.width > narrow.width)
    }

    /// And a narrow one does not shrink the window below the preferred size —
    /// the floor lifts, it never lowers.
    @Test func aNarrowSidebarDoesNotShrinkTheWindow() {
        #expect(frame(sidebar: 10, visible: external).width == CGFloat(1280))
    }

    // MARK: Screens smaller than what we would like

    /// Nothing may open larger than the screen it opens on. This is the case
    /// a fixed default gets wrong, and the reason the clamp is not optional.
    @Test func nothingOpensLargerThanTheScreen() {
        let small = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let result = frame(visible: small)

        #expect(result.width <= small.width)
        #expect(result.height <= small.height)
        #expect(small.contains(result))
    }

    /// Even when the sidebar alone would demand more than the display has.
    /// Overflowing is worse than crowding: a window wider than the screen puts
    /// its own controls off the edge.
    @Test func anImpossibleSidebarStillFitsOnScreen() {
        let small = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let result = frame(sidebar: 900, visible: small)
        #expect(result.width == small.width)
        #expect(small.contains(result))
    }

    /// Whole pixels. A half-point origin makes AppKit draw the window's edge
    /// across two device pixels, which reads as a soft border on a display
    /// where every other edge is crisp.
    @Test func theFrameLandsOnWholePoints() {
        let odd = NSRect(x: 0, y: 0, width: 1365, height: 767)
        let result = frame(visible: odd)
        #expect(result == result.integral)
    }
}

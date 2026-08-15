import CoreGraphics
import Foundation
@testable import Ghostty
import Testing

/// How much of the titlebar strip the panes reserve for themselves.
///
/// The geometry that feeds this — a live window whose titlebar moves into a
/// separate `NSToolbarFullScreenWindow`, and the traffic lights that keep
/// drawing over the strip afterwards — is only observable on screen. What is
/// a calculation is the shortfall: the difference between the strip the
/// window shows and the part of it the window still reserves. One number
/// feeds three places (the sidebar's padding, the terminal filler's bottom,
/// the pane tab bar's top), so these pin it directly, including the case that
/// matters most — where the two measurements agree and nothing may move.
@MainActor
struct SidebarTitlebarInsetTests {
    /// An ordinary window: AppKit stops the content below the strip, so the
    /// sidebar adds nothing and windowed layout is left exactly as it was.
    @Test func anOrdinaryWindowReservesTheStripItself() {
        #expect(SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: 34,
            reservedByWindow: 34
        ) == 0)
    }

    /// Native fullscreen: the titlebar still shows, nothing is reserved, so
    /// the whole strip comes back as the sidebar's own inset.
    @Test func fullscreenPutsTheWholeStripBack() {
        #expect(SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: 32,
            reservedByWindow: 0
        ) == 32)
    }

    /// Only ever the difference, so a strip that is partly reserved cannot
    /// end up inset twice.
    @Test func aPartlyReservedStripPutsBackOnlyTheDifference() {
        #expect(SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: 34,
            reservedByWindow: 10
        ) == 24)
    }

    /// A window reserving more than its strip (an accessory below the
    /// titlebar) must not pull the sidebar's first row upwards.
    @Test func reservingMoreThanTheStripNeverGoesNegative() {
        #expect(SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: 28,
            reservedByWindow: 52
        ) == 0)
    }

    /// The hidden-titlebar style and non-native fullscreen both show no
    /// strip at all, and the sidebar runs to the window's top edge there.
    @Test func noTitlebarAsksForNothing() {
        #expect(SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: 0,
            reservedByWindow: 0
        ) == 0)
    }

    /// Garbage in the reserved measurement (a view that reports a negative
    /// inset) is treated as nothing reserved, not as extra strip.
    @Test func aNegativeReservationIsTreatedAsNone() {
        #expect(SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: 32,
            reservedByWindow: -8
        ) == 32)
    }

    /// The identity the terminal pane's two constraints stand on. Both hang
    /// off the terminal's safe area and take the shortfall as their offset, so
    /// what they actually resolve to is `reserved + shortfall` — and that has
    /// to be the strip itself, never the two measurements added together.
    @Test(arguments: [
        (CGFloat(34), CGFloat(34)),
        (CGFloat(32), CGFloat(0)),
        (CGFloat(34), CGFloat(10)),
        (CGFloat(28), CGFloat(52)),
        (CGFloat(0), CGFloat(0)),
    ])
    func offsettingFromTheSafeAreaLandsOnTheStrip(
        titlebarHeight: CGFloat,
        reservedByWindow: CGFloat
    ) {
        let shortfall = SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: titlebarHeight,
            reservedByWindow: reservedByWindow
        )
        #expect(reservedByWindow + shortfall == max(titlebarHeight, reservedByWindow))
    }
}

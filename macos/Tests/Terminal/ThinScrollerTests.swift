import AppKit
@testable import Ghostty
import Testing

/// The scrollers, which had drifted into two visibly different weights in one
/// window.
///
/// Headless throughout — a scroller draws into an image and never reaches a
/// window, so none of this can hang the suite the way `orderFront` would.
@MainActor
struct ThinScrollerTests {
    /// The measurement that started this: AppKit's legacy scroller is 15
    /// points wide and permanent. Anything near that is the bar the
    /// screenshots complained about.
    @Test func isNarrowerThanTheSystemScroller() {
        let ours = ThinScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let system = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

        #expect(ours < system)
        #expect(ours == ThinScroller.trackWidth)
    }

    /// The width is the same whichever style the system asks for, because the
    /// point is to stop the system deciding it.
    @Test func theWidthDoesNotFollowTheSystemStyle() {
        #expect(
            ThinScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                == ThinScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        )
        #expect(
            ThinScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
                == ThinScroller.trackWidth
        )
    }

    /// Chrome is quieter than content in **both** dimensions. Thinner alone
    /// reads as the same bar seen from further away.
    @Test func chromeIsThinnerAndFainterThanContent() {
        #expect(ThinScroller.Weight.chrome.knobThickness < ThinScroller.Weight.content.knobThickness)
        #expect(ThinScroller.Weight.chrome.knobAlpha < ThinScroller.Weight.content.knobAlpha)
    }

    // MARK: - Where the knob lands

    /// A scroller with no scroll view around it reports an empty knob rect, so
    /// `drawKnob` cannot be measured headless — which is exactly why the
    /// geometry is a pure function and this is what gets asserted. The drawing
    /// itself is one line over this rectangle.
    private let slot = NSRect(x: 0, y: 0, width: ThinScroller.trackWidth, height: 120)

    @Test func theKnobIsNarrowerThanItsTrackAndCentredInIt() {
        let knob = ThinScroller.knobRect(
            inSlot: slot,
            thickness: ThinScroller.Weight.content.knobThickness,
            runsVertically: true
        )

        #expect(knob.width == ThinScroller.Weight.content.knobThickness)
        #expect(knob.width < slot.width)
        #expect(abs(knob.midX - slot.midX) < 0.001, "not centred: \(knob) in \(slot)")
        #expect(slot.contains(knob), "\(knob) escapes \(slot)")
    }

    @Test func chromeDrawsANarrowerKnobThanContent() {
        let content = ThinScroller.knobRect(
            inSlot: slot,
            thickness: ThinScroller.Weight.content.knobThickness,
            runsVertically: true
        )
        let chrome = ThinScroller.knobRect(
            inSlot: slot,
            thickness: ThinScroller.Weight.chrome.knobThickness,
            runsVertically: true
        )

        #expect(chrome.width < content.width)
        #expect(abs(chrome.midX - content.midX) < 0.001, "the two weights are not on the same axis")
    }

    /// Horizontal is the tab bar's case, and it is the one an implementation
    /// written for a vertical bar gets wrong — it would return a knob as tall
    /// as the strip.
    @Test func theHorizontalKnobIsShortRatherThanNarrow() {
        let strip = NSRect(x: 0, y: 0, width: 300, height: ThinScroller.trackWidth)
        let knob = ThinScroller.knobRect(
            inSlot: strip,
            thickness: ThinScroller.Weight.chrome.knobThickness,
            runsVertically: false
        )

        #expect(knob.height == ThinScroller.Weight.chrome.knobThickness)
        #expect(knob.width > knob.height)
        #expect(abs(knob.midY - strip.midY) < 0.001)
        #expect(strip.contains(knob))
    }

    /// A slot thinner than the knob it was asked for. Clamping rather than
    /// overflowing keeps the bar inside the column AppKit allotted it.
    @Test func aSlotThinnerThanTheKnobClampsInsteadOfOverflowing() {
        let pinched = NSRect(x: 0, y: 0, width: 2, height: 60)
        let knob = ThinScroller.knobRect(inSlot: pinched, thickness: 5, runsVertically: true)

        #expect(knob.width <= pinched.width)
        #expect(pinched.contains(knob))
    }

    /// A slot with no length at all — what AppKit hands over for content that
    /// fits, and a scroller that is mid-fade.
    @Test func anEmptySlotProducesNothingToDraw() {
        let knob = ThinScroller.knobRect(inSlot: .zero, thickness: 5, runsVertically: true)
        #expect(knob.width == 0)
    }

    // MARK: - Installing them

    @Test func aScrollViewGetsThinScrollersOnBothAxes() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.useThinScrollers()

        #expect(scrollView.verticalScroller is ThinScroller)
        #expect(scrollView.horizontalScroller is ThinScroller)
    }

    /// Overlay as well as thin, and they are separate halves of the problem:
    /// the width comes from the scroller, the fade comes from the style. A
    /// thin bar parked in the window forever is still a bar parked forever.
    @Test func installingAlsoMakesThemOverlay() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.useThinScrollers()

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
    }

    @Test func theWeightReachesTheInstalledScroller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.useThinScrollers(weight: .chrome)

        #expect((scrollView.verticalScroller as? ThinScroller)?.weight == .chrome)
    }
}

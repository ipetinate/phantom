import AppKit

/// A scroller drawn as a thin, quiet bar instead of the system's.
///
/// AppKit gives a scroll view one of two scrollers, and which one is a *system*
/// preference: with "Show scroll bars: Always" in System Settings, every scroll
/// view gets the **legacy** scroller — 15 points wide, permanently visible,
/// with a filled track. Beside a sidebar that had already been switched to
/// overlay, the same window ended up with two scrollers of visibly different
/// weight, and the wide one sat under the floating controls in the editor's
/// top-right corner.
///
/// So the width stops being the system's business. What remains the system's
/// business is *behaviour* — the fade, the elastic bounce, the click-to-page —
/// which is why this subclasses `NSScroller` rather than drawing a bar from
/// scratch somewhere.
///
/// **Two weights, and the difference is content versus chrome.** A scroller in
/// the editor marks a reader's place in something they are reading, so it stays
/// legible. A scroller in the tab bar or the file tree is only there while a
/// gesture is in flight; it can afford to be almost invisible.
final class ThinScroller: NSScroller {
    enum Weight {
        /// Something the reader is reading — the editor, the diff, a preview.
        case content

        /// Furniture: a tab strip, a tree, a list.
        case chrome

        var knobThickness: CGFloat {
            switch self {
            case .content: 5
            case .chrome: 3.5
            }
        }

        /// How dark the knob is against whatever is behind it. The chrome
        /// weight is fainter as well as thinner — thinner alone reads as the
        /// same bar further away, not as a quieter one.
        var knobAlpha: CGFloat {
            switch self {
            case .content: 0.34
            case .chrome: 0.22
            }
        }
    }

    var weight: Weight = .content

    /// The layout width the scroller claims.
    ///
    /// It stays wider than the knob it draws, on purpose: the knob is what the
    /// eye follows and the frame is what the pointer has to hit, and a 4-point
    /// target is a bar you fight with. Overlay scrollers float over the
    /// content, so this width costs the document nothing.
    static let trackWidth: CGFloat = 11

    override static func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        trackWidth
    }

    override static var isCompatibleWithOverlayScrollers: Bool { true }

    /// Nothing. The system's track is the grey channel that makes a legacy
    /// scroller read as a piece of furniture running down the window.
    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}

    /// Where the knob is drawn inside the space AppKit gave it.
    ///
    /// Pure, and separated from the drawing for the reason the rest of this
    /// editor separates them: a rectangle is three numbers and can be asserted
    /// exhaustively, while `drawKnob` needs a scroller inside a scroll view
    /// inside a window before AppKit will tell it anything.
    static func knobRect(inSlot slot: NSRect, thickness: CGFloat, runsVertically: Bool) -> NSRect {
        let across = runsVertically ? slot.width : slot.height
        let thickness = max(min(thickness, across), 0)

        if runsVertically {
            return NSRect(
                x: slot.midX - thickness / 2,
                y: slot.minY + 1,
                width: thickness,
                height: max(slot.height - 2, thickness)
            )
        }
        return NSRect(
            x: slot.minX + 1,
            y: slot.midY - thickness / 2,
            width: max(slot.width - 2, thickness),
            height: thickness
        )
    }

    override func drawKnob() {
        let slot = rect(for: .knob)
        guard slot.width > 0, slot.height > 0 else { return }

        let knob = Self.knobRect(
            inSlot: slot,
            thickness: weight.knobThickness,
            runsVertically: runsVertically
        )
        let thickness = runsVertically ? knob.width : knob.height

        /// `secondaryLabelColor` rather than a theme colour, and the reason is
        /// the engine boundary: `CodeTextView` installs one of these and
        /// nothing under `Editor/Engine` may name the app's palette. A dynamic
        /// system colour resolves for the appearance it is drawn in, which is
        /// the behaviour a theme would have given it anyway.
        NSColor.secondaryLabelColor.withAlphaComponent(weight.knobAlpha).setFill()
        NSBezierPath(roundedRect: knob, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    /// Whether this scroller runs down the window or across it.
    ///
    /// Read off the frame, which is the same thing AppKit decides it from.
    /// Deliberately not named `isVertical`: `NSScroller` has carried a member
    /// by that name across SDK versions, and a property that silently becomes
    /// an override is a bug that compiles.
    private var runsVertically: Bool { bounds.height >= bounds.width }
}

extension NSScrollView {
    /// Replaces both scrollers with thin ones and makes them overlay.
    ///
    /// Overlay is set here as well as the scrollers, because the two halves of
    /// the problem are separate: the *width* comes from the scroller, and the
    /// *permanence* comes from the style. Leaving the style alone would keep a
    /// thin bar parked in the window forever for anybody whose System Settings
    /// say to always show scroll bars.
    ///
    /// Call after `hasVerticalScroller` / `hasHorizontalScroller` are set —
    /// AppKit builds its own scroller when those turn on, and this replaces it.
    func useThinScrollers(weight: ThinScroller.Weight = .content) {
        scrollerStyle = .overlay
        autohidesScrollers = true

        let vertical = ThinScroller()
        vertical.weight = weight
        verticalScroller = vertical

        let horizontal = ThinScroller()
        horizontal.weight = weight
        horizontalScroller = horizontal
    }
}

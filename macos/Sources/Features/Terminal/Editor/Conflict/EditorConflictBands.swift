import AppKit

/// The colour behind a conflict's two sides.
///
/// A view under the text rather than attributes on it. The syntax highlighter
/// owns the text storage and rewrites its attributes around every edit, over a
/// range that reaches well past the edit itself — a background colour written
/// there would be erased by the next keystroke near it, and re-written by this,
/// and the two would take turns. Paint that nothing else touches cannot lose
/// that argument.
///
/// It sits in the clip view under the text view, which is where
/// `CurrentLineBandView` sits and for the same reason: the clip view scrolls by
/// moving its bounds, so everything in it moves together for free.
final class EditorConflictBandsView: NSView {
    /// One painted run, in the coordinates of the text view above.
    struct Band: Equatable {
        let rect: NSRect
        let color: NSColor
    }

    private var bands: [Band] = []

    override var isFlipped: Bool { true }

    /// Clicks belong to the text above; this is paint, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setBands(_ bands: [Band]) {
        guard bands != self.bands else { return }
        self.bands = bands
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for band in bands where band.rect.intersects(dirtyRect) {
            band.color.setFill()
            band.rect.fill()
        }
    }

    /// The colours the two sides and the markers take.
    ///
    /// Derived from the diff palette rather than chosen, so a conflict reads
    /// as the same green and red as every other "mine" and "theirs" in the
    /// app — and so a light theme gets the darker pair without this knowing
    /// how that works. The marker lines take a stronger wash than the content
    /// because they are the structure rather than the code.
    struct Palette: Equatable {
        let current: NSColor
        let incoming: NSColor
        let base: NSColor
        let marker: NSColor

        /// What the action bar is painted with.
        ///
        /// Opaque, and built by compositing the marker wash onto the editor's
        /// own background rather than by using the wash directly: the bar
        /// covers a line of text, and a translucent colour would let that text
        /// show through — which is the collision the bar exists to end.
        let barBackground: NSColor

        init(diff: GitDiffPalette, theme: CodeTheme) {
            current = diff.removedBackground
            incoming = diff.addedBackground
            base = theme.foreground.withAlphaComponent(0.06)
            marker = theme.foreground.withAlphaComponent(0.10)
            barBackground = Palette.opaque(marker, over: theme.background)
        }

        /// The colour a button takes to say which side it keeps.
        ///
        /// The band's own colour, composited onto the bar so it is opaque —
        /// the same wash over the same background the line itself gets, which
        /// is what makes "this button gives you the red one" legible without a
        /// legend. Nil for a choice that keeps more than one side: `both` has
        /// no single colour, and inventing one would say something false.
        func color(for choice: EditorConflict.Choice) -> NSColor? {
            switch choice {
            case .current: return Palette.opaque(current, over: barBackground)
            case .incoming: return Palette.opaque(incoming, over: barBackground)
            case .base: return Palette.opaque(base, over: barBackground)
            case .both: return nil
            }
        }

        /// One colour over another, resolved to a colour with no alpha left.
        static func opaque(_ top: NSColor, over bottom: NSColor) -> NSColor {
            guard let over = top.usingColorSpace(.sRGB),
                  let under = bottom.usingColorSpace(.sRGB)
            else { return bottom }

            let alpha = over.alphaComponent
            return NSColor(
                srgbRed: over.redComponent * alpha + under.redComponent * (1 - alpha),
                green: over.greenComponent * alpha + under.greenComponent * (1 - alpha),
                blue: over.blueComponent * alpha + under.blueComponent * (1 - alpha),
                alpha: 1
            )
        }
    }
}

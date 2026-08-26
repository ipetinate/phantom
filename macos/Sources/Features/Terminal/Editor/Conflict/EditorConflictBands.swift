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
    struct Palette {
        let current: NSColor
        let incoming: NSColor
        let base: NSColor
        let marker: NSColor

        init(diff: GitDiffPalette, theme: CodeTheme) {
            current = diff.removedBackground
            incoming = diff.addedBackground
            base = theme.foreground.withAlphaComponent(0.06)
            marker = theme.foreground.withAlphaComponent(0.10)
        }
    }
}

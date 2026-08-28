import AppKit

/// Draws the wave under each problem.
///
/// ## Why a view and not a text attribute
///
/// AppKit can underline text, and it can only underline it straight:
/// `NSUnderlineStyle` has a single, a double, a thick and a dotted, and no
/// wave. So the mark has to be drawn, and the question is only where from.
///
/// **Not from `NSTextView.draw(_:)`.** Overriding that method silently drops
/// an `NSTextView` to TextKit 1 — measured, and held by
/// `TextKitDowngradeTests` — which lays out the whole document instead of the
/// viewport and blanks the gutter, since the gutter walks TextKit 2
/// fragments. `CurrentLineBandView` exists for the same reason and records
/// the same finding.
///
/// So: an ordinary view, in front of the text rather than behind it, which
/// paints and is never asked about anything else. It is a subview of the text
/// view — like the conflict bars and the blame ghost — which is what makes it
/// scroll with the document for free: it is *in* the document, so the clip
/// view moves it with everything else and only the newly exposed strip is
/// ever redrawn.
///
/// ## Why it survives scrolling and re-layout
///
/// It holds nothing. Every draw reads the ranges out of the text storage and
/// the geometry out of the layout manager, both of which are current by
/// definition. There is no cached bitmap to go stale, no remembered rect to
/// be left behind by a re-wrap, and no list of line numbers to be invalidated
/// by an edit — the ranges are attributes, so the text storage moves them
/// when the text under them moves.
final class CodeSquiggleView: NSView {
    /// The text this marks up. Weak, and this view is inside it: the text view
    /// owns this, not the other way round.
    weak var textView: NSTextView?

    /// A document small enough to scan whole when the layout manager cannot
    /// yet say what is on screen.
    ///
    /// Only the very first draw of a freshly opened file is in that state, and
    /// answering "nothing" there is how a squiggle fails to appear until the
    /// reader scrolls. Above this size the scan itself would be the cost the
    /// viewport exists to avoid, so a large file waits the one frame instead.
    private static let wholeDocumentLimit = 20_000

    /// Same coordinates as the text view it sits in, so a rect computed
    /// against one needs no conversion for the other.
    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    /// Paint, not a control. Every click, drag and right-click belongs to the
    /// text underneath — a view that answered here would make the code
    /// unselectable wherever it had an error.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    /// Repaints. Called when the diagnostics change, when the text changes,
    /// and when the reader turns the underlines off.
    func refresh() {
        needsDisplay = true
    }

    /// One wave, worked out and not yet drawn.
    ///
    /// Split out of `draw` so the geometry can be asserted against a real
    /// laid-out document without a window, a screen or a drawing context —
    /// which is the only way to hold the two things a reader would actually
    /// report: that the mark covers the characters the problem covers and
    /// nothing else, and that it stays on its own line.
    struct Mark: Equatable {
        var colour: NSColor

        /// The glyphs being marked, in this view's coordinates.
        var rect: CGRect

        /// The text baseline of those glyphs, in the same space. Carried so
        /// the one invariant worth holding is checkable: no part of the wave
        /// is drawn above it.
        var baseline: CGFloat

        /// The middle of the wave, in the same space.
        var centreY: CGFloat

        var fontSize: CGFloat
    }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks(in: dirtyRect) {
            mark.colour.setStroke()
            CodeSquiggle.path(
                x: mark.rect.minX,
                width: mark.rect.width,
                centreY: mark.centreY,
                fontSize: mark.fontSize
            )?.stroke()
        }
    }

    /// Every wave that falls inside `dirtyRect`.
    ///
    /// Holds nothing between calls: the ranges come out of the text storage
    /// and the rectangles out of the layout manager, both of which are
    /// current by definition. That is what makes this survive a scroll, a
    /// re-wrap and an edit with no artefacts — there is no cached bitmap to
    /// go stale and no remembered rectangle to be left behind.
    /// The reader's switch is deliberately **not** read here. It is applied
    /// where the attribute is written — `Coordinator.applyUnderlines` marks
    /// nothing when underlining is off — so a second check here would be a
    /// second place for the answer to live, and this view would have to name
    /// the app's settings to ask it. Nothing marked, nothing drawn.
    func marks(in dirtyRect: NSRect) -> [Mark] {
        guard let textView,
              let storage = textView.textStorage,
              let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let scanned = Self.scanRange(
                layout: layout,
                content: content,
                length: storage.length)
        else { return [] }

        let fontSize = textView.font?.pointSize ?? 12
        let amplitude = CodeSquiggle.amplitude(forFontSize: fontSize)
        let stroke = CodeSquiggle.lineWidth(forFontSize: fontSize)
        let origin = textView.textContainerOrigin
        let documentStart = content.documentRange.location

        /// Padded by exactly what a wave can hang below its own line, and no
        /// more. Too little and repainting the strip under a marked line
        /// erases the part that hangs into it with nothing to put it back;
        /// too much and every repaint drags in the neighbouring lines'
        /// segments for no reason. See `CodeSquiggle.maximumOverhang`.
        let overhang = CodeSquiggle.maximumOverhang(forFontSize: fontSize)
        let interesting = dirtyRect.insetBy(dx: -overhang, dy: -overhang)

        var found: [Mark] = []
        storage.enumerateAttribute(.codeDiagnosticUnderline, in: scanned, options: []) { value, range, _ in
            guard let colour = value as? NSColor, range.length > 0,
                  let from = content.location(documentStart, offsetBy: range.location),
                  let to = content.location(documentStart, offsetBy: NSMaxRange(range)),
                  let textRange = NSTextRange(location: from, end: to)
            else { return }

            layout.enumerateTextSegments(in: textRange, type: .standard) { _, frame, baselinePosition, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                guard rect.width > 0.5, rect.height > 0, rect.intersects(interesting) else { return true }

                /// The layout manager's own baseline where it has one. A
                /// segment it reports without one is a segment with no glyphs
                /// laid out yet, and the bottom of the fragment is the only
                /// honest guess left.
                let baseline = baselinePosition > 0 ? rect.minY + baselinePosition : rect.maxY

                found.append(Mark(
                    colour: colour,
                    rect: rect,
                    baseline: baseline,
                    centreY: CodeSquiggle.centreY(
                        baseline: baseline,
                        bottom: rect.maxY,
                        amplitude: amplitude,
                        lineWidth: stroke
                    ),
                    fontSize: fontSize
                ))
                return true
            }
        }
        return found
    }

    /// Which characters are worth looking at.
    ///
    /// The laid-out viewport, not the document. `enumerateAttribute` walks
    /// *attribute runs*, and this storage has one per syntax token — so
    /// scanning a fifty-thousand-line file for a handful of diagnostics would
    /// cost a walk over every token in it, on every frame of a scroll.
    private static func scanRange(
        layout: NSTextLayoutManager,
        content: NSTextContentManager,
        length: Int
    ) -> NSRange? {
        guard length > 0 else { return nil }

        guard let viewport = layout.textViewportLayoutController.viewportRange else {
            return length <= wholeDocumentLimit ? NSRange(location: 0, length: length) : nil
        }

        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let clampedStart = min(max(start, 0), length)
        let clampedEnd = min(max(end, clampedStart), length)
        return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
    }
}

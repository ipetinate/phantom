import AppKit

extension NSAttributedString.Key {
    /// The colour a problem is drawn in, carried on the characters it covers.
    ///
    /// A key of this editor's own rather than `.underlineStyle`, and the
    /// difference is what makes the wave possible at all: `NSUnderlineStyle`
    /// has no wave, so a diagnostic drawn by AppKit can only ever be a
    /// straight rule. The value is the severity's `NSColor` and nothing else —
    /// where a problem is, is the range the attribute is set over.
    ///
    /// It is still an *attribute* rather than a list of ranges held beside the
    /// text, because `NSTextStorage` moves attributes when the text under them
    /// moves. A list of plain ranges would point at the wrong characters from
    /// the first keystroke after a diagnostic arrived, which is the moment the
    /// reader is most likely to be looking at it.
    ///
    /// Nothing draws it: it is inert to AppKit, and `CodeSquiggleView` is the
    /// only reader.
    static let codeDiagnosticUnderline = NSAttributedString.Key("codeDiagnosticUnderline")
}

/// The shape of the line drawn under a problem.
///
/// A zig-zag rather than a rule, which is what every editor a reader arrives
/// from draws and what was asked for by name. Spelled as arithmetic over
/// values — no view, no layout manager, no font — so the part that is easy to
/// get wrong can be asserted directly: that it scales with the type, that it
/// stops where the problem stops, and that it stays on its own line.
///
/// ## Why it is scaled rather than fixed
///
/// A wave with a constant wavelength is two different drawings at the two
/// ends of a font-size picker. At 9pt a 6pt wave has barely one full period
/// under a three-character word and reads as a smear; at 24pt the same wave
/// is a decoration a reader notices before they notice the word. Both
/// measurements therefore come from the point size, and both are clamped: the
/// ratio is right in the middle of the range and wrong at the extremes, where
/// a sub-pixel amplitude disappears into antialiasing and a large one starts
/// colliding with the line below.
enum CodeSquiggle {
    /// The distance between two peaks.
    ///
    /// Half the point size — 6pt under a 12pt font, which is the period VS
    /// Code's own squiggle uses at its default size. Floored at 3 because
    /// below that the peaks land inside one another and the wave fills in
    /// solid; capped at 12 because past it the reader is looking at a single
    /// long chevron rather than at an underline.
    static func wavelength(forFontSize size: CGFloat) -> CGFloat {
        min(max(size * 0.5, 3), 12)
    }

    /// Half the peak-to-peak height.
    ///
    /// 1.4pt under a 12pt font, so the wave stands about 2.8pt tall — the
    /// same proportion as the reference above. The floor keeps it visible on
    /// a non-retina display, where anything under three quarters of a point
    /// is a grey blur rather than a line.
    static func amplitude(forFontSize size: CGFloat) -> CGFloat {
        min(max(size * 0.115, 0.75), 3)
    }

    /// How thick the stroke is. One point at 12, which is the width AppKit
    /// gives a single underline, so the squiggle reads as the same weight of
    /// mark rather than as a heavier one.
    static func lineWidth(forFontSize size: CGFloat) -> CGFloat {
        min(max(size / 12, 0.75), 2)
    }

    /// How far below its own line the wave may reach.
    ///
    /// Measured rather than assumed, because it is not zero and something has
    /// to know by how much. A 12pt monospaced line lays out 15pt tall with
    /// its baseline at 12, so there are three points of descent to put a wave
    /// in that stands 3.76 — it does not fit, and `centreY` resolves that by
    /// keeping the peak on the baseline and letting the trough hang under the
    /// line by the difference.
    ///
    /// The consumer of this number is the redraw. A wave that hangs into the
    /// strip below it has to be *found* when that strip is repainted, or the
    /// repaint erases it and nothing puts it back — which is exactly the
    /// artefact that a mark drawn outside its own line invites. So the scan
    /// pads by this, and the padding is not a guess.
    static func maximumOverhang(forFontSize size: CGFloat) -> CGFloat {
        amplitude(forFontSize: size) + lineWidth(forFontSize: size) / 2
    }

    /// Where the middle of the wave sits, in a flipped coordinate space.
    ///
    /// Below the baseline by its own amplitude and a hair more, so the
    /// topmost peak clears the glyphs rather than cutting through them — and
    /// then clamped so the bottom trough stays inside the line fragment where
    /// there is room for it.
    ///
    /// **Where there is not, the peak wins.** A line has only as much space
    /// under the baseline as the font's descent, and at ordinary sizes that
    /// is less than the wave is tall — measured, on a 12pt monospaced line:
    /// three points of descent for a mark that stands nearly four. Something
    /// has to give, and the choice is between a peak drawn through the bottom
    /// of the letters and a trough hanging a fraction of a point into the top
    /// of the line below, which is empty space — every glyph on that line
    /// starts at *its* baseline, a full ascent further down. The letters win.
    /// `maximumOverhang` is how much hangs over, and the redraw is padded by
    /// it so nothing is left behind.
    ///
    /// - Parameter baseline: the text baseline, in the same space as `bottom`.
    /// - Parameter bottom: the bottom of the line fragment.
    static func centreY(
        baseline: CGFloat,
        bottom: CGFloat,
        amplitude: CGFloat,
        lineWidth: CGFloat
    ) -> CGFloat {
        let reach = amplitude + lineWidth / 2
        let wanted = baseline + amplitude + lineWidth
        let highest = baseline + reach
        let lowest = bottom - reach
        guard lowest > highest else { return highest }
        return min(max(wanted, highest), lowest)
    }

    /// The vertices of the wave across `width`, starting at `x`.
    ///
    /// The first vertex is on the centre line and every one after it
    /// alternates above and below it, a half wavelength apart — so a period
    /// is a peak and a trough, and the mark starts flat rather than at an
    /// extreme.
    ///
    /// **The last vertex is pulled back to the end of the range** rather than
    /// left wherever the rhythm happens to fall. That is the difference
    /// between a squiggle under `foo` and a squiggle under `foo` plus most of
    /// the space after it, which is what a reader reads as "the whole line is
    /// wrong". It costs the final peak its full height, which is invisible,
    /// and it is why a three-character problem is marked over three
    /// characters.
    ///
    /// A run narrower than one wavelength gets the wavelength squeezed down
    /// to its own width rather than the flat dash it would otherwise be. A
    /// problem on a single character is common — an unexpected token, a
    /// stray bracket — and marking it with a short straight line is marking
    /// it the old way, on exactly the case that reads worst.
    ///
    /// Empty for a range with no width: there is nothing to mark, and a path
    /// of one point strokes a dot.
    static func points(
        x: CGFloat,
        width: CGFloat,
        centreY: CGFloat,
        wavelength: CGFloat,
        amplitude: CGFloat
    ) -> [CGPoint] {
        guard width > 0, wavelength > 0 else { return [] }

        let step = min(wavelength, width) / 2
        var points: [CGPoint] = [CGPoint(x: x, y: centreY)]
        var offset = step
        var up = true

        while offset < width {
            points.append(CGPoint(x: x + offset, y: centreY + (up ? -amplitude : amplitude)))
            offset += step
            up.toggle()
        }

        let end = CGPoint(x: x + width, y: centreY)
        if let last = points.last, last.x >= end.x {
            points[points.count - 1] = end
        } else {
            points.append(end)
        }
        return points.count >= 2 ? points : []
    }

    /// The same vertices as a stroked path.
    ///
    /// Round joins, because a mitre on a 60-degree turn grows a spike taller
    /// than the wave itself — which at 9pt is most of what the reader sees.
    static func path(
        x: CGFloat,
        width: CGFloat,
        centreY: CGFloat,
        fontSize: CGFloat
    ) -> NSBezierPath? {
        let vertices = points(
            x: x,
            width: width,
            centreY: centreY,
            wavelength: wavelength(forFontSize: fontSize),
            amplitude: amplitude(forFontSize: fontSize)
        )
        guard vertices.count >= 2 else { return nil }

        let path = NSBezierPath()
        path.lineWidth = lineWidth(forFontSize: fontSize)
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: vertices[0])
        for vertex in vertices.dropFirst() { path.line(to: vertex) }
        return path
    }
}

/// A diagnostic, carried by the text itself.
///
/// **A reference type because it rides in a text attribute**, and it holds the
/// problem rather than only its colour so that everything the editor says
/// about a diagnostic comes from one moving source.
///
/// The alternative was a list of ranges resolved when the server last spoke,
/// which is what the hover card used to read. `NSTextStorage` moves an
/// attribute when the text under it moves; a list does not. So between an edit
/// and the server's next answer the two disagreed — the wave stayed under the
/// symbol and the card, asked about the same symbol, looked up a range that
/// had shifted and found nothing. Reported as an error with an underline and
/// no message, in a file that had been edited since the last diagnostics
/// arrived.
final class CodeDiagnosticMark: NSObject {
    let message: String
    let source: String?
    let color: NSColor

    init(message: String, source: String?, color: NSColor) {
        self.message = message
        self.source = source
        self.color = color
    }
}

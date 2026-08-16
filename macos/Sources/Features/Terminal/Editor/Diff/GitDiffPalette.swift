import AppKit

/// The colours a diff is drawn in, derived from the editor's own theme.
///
/// Derived rather than fixed, because a diff drawn in GitHub's greens and
/// reds on top of a dark Dracula editor looks like a different application
/// opened inside the window. The hues are the two everyone reads as added
/// and removed; what comes from the theme is how strongly they sit against
/// *this* background.
struct GitDiffPalette {
    let addedBackground: NSColor
    let removedBackground: NSColor

    /// A stronger wash for the characters that actually differ within a
    /// line, drawn over the line's own band.
    let addedEmphasis: NSColor
    let removedEmphasis: NSColor

    /// The band marking lines the diff skipped over.
    let gapBackground: NSColor
    let gapForeground: NSColor

    static func make(from theme: CodeTheme) -> GitDiffPalette {
        /// Whether the editor is dark decides the alpha, not the hue. The
        /// same green at the same strength is a whisper on white and a
        /// highlighter stripe on near-black.
        let isDark = theme.background.brightnessComponentApproximation < 0.5
        let base: CGFloat = isDark ? 0.22 : 0.16
        let emphasis: CGFloat = isDark ? 0.38 : 0.30

        let green = NSColor(srgbRed: 0.28, green: 0.72, blue: 0.35, alpha: 1)
        let red = NSColor(srgbRed: 0.88, green: 0.31, blue: 0.33, alpha: 1)

        return GitDiffPalette(
            addedBackground: green.withAlphaComponent(base),
            removedBackground: red.withAlphaComponent(base),
            addedEmphasis: green.withAlphaComponent(emphasis),
            removedEmphasis: red.withAlphaComponent(emphasis),
            gapBackground: theme.foreground.withAlphaComponent(isDark ? 0.06 : 0.05),
            gapForeground: theme.lineNumber
        )
    }
}

extension NSColor {
    /// Perceived brightness without going through a colour space conversion
    /// that can fail.
    ///
    /// `brightnessComponent` traps on a colour that is not in a
    /// device/calibrated space, and a theme's background can arrive as a
    /// pattern or a catalog colour. This answers for every colour, and it
    /// only ever decides between two alpha values — a wrong answer at the
    /// boundary costs a slightly weak tint, not a crash.
    var brightnessComponentApproximation: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
}

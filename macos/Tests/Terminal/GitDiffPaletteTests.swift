import AppKit
@testable import Ghostty
import Testing

/// The diff's colours, checked for the property the pane now depends on.
///
/// `GitDiffPane` paints no base colour of its own: it sits on the single
/// layer the host puts behind the whole editor pane, which is what lets a
/// solid theme and a window blurred through to the desktop reach a diff the
/// same way they reach code. Every band the diff draws is therefore
/// composited over something it does not own — so an opaque one would cover
/// that layer up and put the panel back, one row at a time.
struct GitDiffPaletteTests {
    private func theme(background: NSColor) -> CodeTheme {
        CodeTheme(
            foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
            background: background,
            tokens: [:],
            lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
            currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
            currentLineBackground: nil
        )
    }

    private var darkTheme: CodeTheme { theme(background: NSColor(calibratedWhite: 0.08, alpha: 1)) }
    private var lightTheme: CodeTheme { theme(background: NSColor(calibratedWhite: 0.97, alpha: 1)) }

    private func fills(_ palette: GitDiffPalette) -> [NSColor] {
        [
            palette.addedBackground,
            palette.removedBackground,
            palette.addedEmphasis,
            palette.removedEmphasis,
            palette.gapBackground,
        ]
    }

    @Test func everyBandTheDiffPaintsLetsThePaneBehindItThrough() {
        for theme in [darkTheme, lightTheme] {
            for fill in fills(GitDiffPalette.make(from: theme)) {
                #expect(fill.alphaComponent > 0)
                #expect(fill.alphaComponent < 1)
            }
        }
    }

    /// The characters that actually differ are washed over the band their
    /// own line already carries, so the emphasis only reads as emphasis
    /// while it is the stronger of the two.
    @Test func emphasisIsStrongerThanTheBandItIsDrawnOver() {
        for theme in [darkTheme, lightTheme] {
            let palette = GitDiffPalette.make(from: theme)
            #expect(palette.addedEmphasis.alphaComponent > palette.addedBackground.alphaComponent)
            #expect(palette.removedEmphasis.alphaComponent > palette.removedBackground.alphaComponent)
        }
    }

    /// A dark theme takes the stronger wash, because the same green at the
    /// same strength is a whisper on white and a highlighter stripe on
    /// near-black — the one thing the palette reads off the theme.
    @Test func aDarkThemeTakesAStrongerWashThanALightOne() {
        let dark = GitDiffPalette.make(from: darkTheme)
        let light = GitDiffPalette.make(from: lightTheme)

        #expect(dark.addedBackground.alphaComponent > light.addedBackground.alphaComponent)
        #expect(dark.removedBackground.alphaComponent > light.removedBackground.alphaComponent)
    }
}

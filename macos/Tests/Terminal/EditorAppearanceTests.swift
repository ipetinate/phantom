import AppKit
@testable import Ghostty
import Testing

/// The appearance pass, which used to run over the whole document on every
/// SwiftUI update.
///
/// That is what made ⌘S blank the top of the file and move the cursor a line:
/// saving publishes the text, a publish is an update, and the update rewrote
/// every attribute in the storage. The guard is the fix, so these assert the
/// two values it compares really do compare.
@MainActor
struct AppearanceGuardTests {
    private var theme: CodeTheme { .fallback }

    @Test func anIdenticalThemeCompareEqual() {
        #expect(CodeTheme.fallback == CodeTheme.fallback)
    }

    @Test func aChangedColorIsNoticed() {
        var changed = CodeTheme.fallback
        changed.foreground = .systemPink
        #expect(changed != CodeTheme.fallback)
    }

    /// The current-line band is part of the theme, so turning it on has to
    /// count as a change — otherwise the guard would swallow it.
    @Test func changingTheCurrentLineBandIsAChange() {
        var changed = CodeTheme.fallback
        changed.currentLineBackground = NSColor.white.withAlphaComponent(0.05)
        #expect(changed != CodeTheme.fallback)
    }

    @Test func anIdenticalConfigurationComparesEqual() {
        #expect(CodeEditorConfiguration.default == CodeEditorConfiguration.default)
    }

    /// Wrapping decides whether the text view may be wider than the viewport,
    /// which is what horizontal scrolling depends on — it must not be a
    /// change the guard hides.
    @Test func changingWrappingIsAChange() {
        var changed = CodeEditorConfiguration.default
        changed.wrapsLines.toggle()
        #expect(changed != CodeEditorConfiguration.default)
    }

    @Test func changingTheCurrentLineFlagIsAChange() {
        var changed = CodeEditorConfiguration.default
        changed.highlightsCurrentLine.toggle()
        #expect(changed != CodeEditorConfiguration.default)
    }

    @Test func changingBracketColoringIsAChange() {
        var changed = CodeEditorConfiguration.default
        changed.colorsBracketPairs.toggle()
        #expect(changed != CodeEditorConfiguration.default)
    }
}

/// The current-line highlight.
///
/// Both colours were already in the theme and populated by the host — nothing
/// drew them, which is why the feature appeared missing rather than broken.
///
/// Built through `EditorTheme.make(colors:background:)` — the pure half —
/// rather than `.make(from: ThemePalette.shared)`: the live palette is
/// whatever the running app happens to have loaded, and on a clean checkout
/// with no config yet read (a fresh CI runner, notably) that is fewer than
/// sixteen colours, which falls back to `.fallback` and its `nil` band. That
/// made these assert something true about an *empty* palette, not about the
/// mapping this file exists to describe.
@MainActor
struct CurrentLineHighlightTests {
    /// Sixteen distinct colours, indexable the way a real ANSI palette is —
    /// the shape `make` requires, with no meaning attached to the values
    /// beyond being different from one another.
    private var samplePalette: [NSColor] {
        (0..<16).map { NSColor(white: CGFloat($0) / 16, alpha: 1) }
    }

    @Test func theHostSuppliesBothColours() {
        let theme = EditorTheme.make(colors: samplePalette, background: nil)
        #expect(theme.currentLineBackground != nil)
        #expect(theme.currentLineNumber != theme.lineNumber)
    }

    /// Subtle by construction: a band you can read *through*. An opaque fill
    /// would hide the window's blur, which the editor deliberately lets reach
    /// the code.
    @Test func theBandIsTranslucent() {
        let theme = EditorTheme.make(colors: samplePalette, background: nil)
        guard let band = theme.currentLineBackground else {
            Issue.record("the host stopped supplying a band colour")
            return
        }
        #expect(band.alphaComponent < 0.2)
    }

    /// Turning it off in the configuration has to reach the view, or the
    /// setting would be decoration.
    @Test func theConfigurationCanTurnItOff() {
        var configuration = CodeEditorConfiguration.default
        configuration.highlightsCurrentLine = false
        #expect(!configuration.highlightsCurrentLine)
    }

    /// The band is the caret's line and nothing else of its own: whatever
    /// vertical the caret was measured at is the vertical it gets.
    ///
    /// This says nothing about *when* that measurement is taken, which is the
    /// half that broke — a band that trailed the caret by a line more on each
    /// Enter had geometry as correct as this and a stale rect to apply it to.
    /// Only the running app can show that one.
    @Test func theBandTakesTheCaretsLine() {
        let frame = CodeTextView.Coordinator.bandFrame(
            caret: NSRect(x: 42, y: 120, width: 0, height: 15),
            documentWidth: 300,
            clipWidth: 800
        )
        #expect(frame.minY == CGFloat(120))
        #expect(frame.height == CGFloat(15))
    }

    /// A file of short lines makes the document narrower than the viewport,
    /// and a band that stopped at the document would stop in mid-air.
    @Test func theBandSpansTheViewportWhenTheDocumentIsNarrower() {
        let frame = CodeTextView.Coordinator.bandFrame(
            caret: NSRect(x: 42, y: 120, width: 0, height: 15),
            documentWidth: 300,
            clipWidth: 800
        )
        #expect(frame.minX == CGFloat(0))
        #expect(frame.width == CGFloat(800))
    }

    /// And a long line scrolled sideways makes it the other way around, where
    /// stopping at the viewport would leave the band behind as you scroll.
    @Test func theBandSpansTheDocumentWhenItIsWider() {
        let frame = CodeTextView.Coordinator.bandFrame(
            caret: NSRect(x: 42, y: 120, width: 0, height: 15),
            documentWidth: 2_000,
            clipWidth: 800
        )
        #expect(frame.width == CGFloat(2_000))
    }
}

/// The line numbers beside the text, and the last line of a file.
///
/// A file that ends in a newline shows one more line than it has text for, and
/// TextKit hands that empty line back inside the *last* fragment rather than as
/// one of its own — one frame, two rows. The gutter drew one number per
/// fragment, centred in its frame, so the last number floated between the two
/// rows and the final line got none at all. That is every file in this repo.
///
/// These pin the split. Whether the number lands on the right pixel is a thing
/// only the running app can show.
@MainActor
struct GutterLineNumberTests {
    /// The ordinary fragment: nothing appended, nothing to divide.
    @Test func aFragmentWithoutAnAppendedLineIsOneRow() {
        let split = CodeGutterView.rowSplit(fragmentHeight: 15, extraLineHeight: 0)
        #expect(split.numbered == CGFloat(15))
        #expect(split.extraOffset == CGFloat(15))
    }

    /// The last fragment of a file ending in a newline: half of it is the
    /// appended empty line, and the number belongs in the other half.
    @Test func anAppendedLineTakesItsOwnRow() {
        let split = CodeGutterView.rowSplit(fragmentHeight: 30, extraLineHeight: 15)
        #expect(split.numbered == CGFloat(15))
        #expect(split.extraOffset == CGFloat(15))
    }

    /// A soft-wrapped last line is three rows, one of them appended — the
    /// number still centres over the text, which is the two that have any.
    @Test func wrappingLeavesTheAppendedLineOneRowOfItsOwn() {
        let split = CodeGutterView.rowSplit(fragmentHeight: 45, extraLineHeight: 15)
        #expect(split.numbered == CGFloat(30))
        #expect(split.extraOffset == CGFloat(30))
    }

    /// Garbage in — an appended line taller than the fragment holding it —
    /// must not put the number above the fragment it belongs to.
    @Test func anImpossibleSplitNeverGoesNegative() {
        let split = CodeGutterView.rowSplit(fragmentHeight: 15, extraLineHeight: 30)
        #expect(split.numbered == CGFloat(0))
    }
}

/// The horizontal offset the editor is allowed to rest at.
///
/// Entering native fullscreen left the clip view scrolled 9 points right — the
/// text container inset plus its line fragment padding — with every other
/// measurement identical to the windowed layout, so the first character of
/// every line was drawn outside what the clip showed. It survived leaving
/// fullscreen and cleared only on a tab switch.
@MainActor
struct EditorHorizontalSnapTests {
    /// The margin itself, and everything inside it, is not a scroll position:
    /// there is nothing to the left of the first glyph to bring into view.
    @Test(arguments: [CGFloat(0.5), CGFloat(4), CGFloat(9)])
    func anOffsetInsideTheMarginGoesBackToZero(offset: CGFloat) {
        #expect(CodeTextView.Coordinator.horizontalSnap(offset: offset, margin: 9) == CGFloat(0))
    }

    /// Already home. Correcting it would post a scroll on every bounds change
    /// for no reason.
    @Test func zeroIsLeftAlone() {
        #expect(CodeTextView.Coordinator.horizontalSnap(offset: 0, margin: 9) == nil)
    }

    /// Past the margin the reader is really scrolled sideways, and moving them
    /// back would fight them.
    @Test(arguments: [CGFloat(9.5), CGFloat(120), CGFloat(4_000)])
    func aRealScrollPositionIsUntouched(offset: CGFloat) {
        #expect(CodeTextView.Coordinator.horizontalSnap(offset: offset, margin: 9) == nil)
    }

    /// Wrapping leaves no margin to be inside of, and nothing to scroll.
    @Test func noMarginCorrectsNothing() {
        #expect(CodeTextView.Coordinator.horizontalSnap(offset: 3, margin: 0) == nil)
    }
}

/// The environment badge's colour scale.
struct EnvironmentBadgeTests {
    /// Inverted on purpose: green is the one you are *meant* to break.
    @Test func developmentIsTheCalmColour() {
        #expect(DevelopmentBuild.environment == .development)
        #expect(DevelopmentBuild.Environment.development.label == "DEV")
    }

    @Test func everyEnvironmentHasItsOwnLabel() {
        let labels = [
            DevelopmentBuild.Environment.development,
            .staging,
            .production,
        ].map(\.label)
        #expect(Set(labels).count == 3)
    }
}

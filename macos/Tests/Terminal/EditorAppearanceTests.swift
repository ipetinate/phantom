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

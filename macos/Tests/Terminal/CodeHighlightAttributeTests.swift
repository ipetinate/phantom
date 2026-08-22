import AppKit
@testable import Ghostty
import Testing

/// What a recolour is allowed to erase.
///
/// The reset in `highlight(_:in:preserving:)` is what stops stale colour from
/// outliving an edit — and it used to take the diagnostic underline with it.
/// The squiggle vanished the moment the line under it was touched, which is
/// the one moment a reader is looking at that line, and the underline
/// *colour* went too: that colour is the whole of the severity, so what came
/// back after the next full pass could not say whether it was a warning or an
/// error.
@MainActor
struct CodeHighlightAttributeTests {
    /// Concrete colours rather than `CodeTheme.fallback`, whose `.textColor`
    /// is a dynamic catalog colour with no components to compare outside a
    /// drawing context — the reason `CodeCompletionPanelTests` builds its own.
    private let theme = CodeTheme(
        foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
        background: NSColor(calibratedWhite: 0.1, alpha: 1),
        tokens: [.keyword: NSColor(calibratedRed: 0.8, green: 0.4, blue: 1, alpha: 1)],
        lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
        currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
        currentLineBackground: nil
    )

    private let severity = NSColor(calibratedRed: 1, green: 0.25, blue: 0.2, alpha: 1)

    private func engine() -> CodeTextStorage {
        CodeTextStorage(language: .swift, theme: theme, configuration: .default)
    }

    /// Two lines, so a recolour can cover one of them and leave the other.
    private static let source = "let a = 1\nlet b = 2\n"

    private func underlined(_ text: String = source, over range: NSRange) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        storage.addAttributes(
            [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: severity,
            ],
            range: range
        )
        return storage
    }

    private func whole(_ storage: NSTextStorage) -> NSRange {
        NSRange(location: 0, length: storage.length)
    }

    // MARK: The underline survives

    /// Both keys, because only one of them was ever the visible half of the
    /// bug: a style with no colour is still a squiggle, in the text colour,
    /// which reads as an error under every line that has a warning.
    @Test func aRecolourPutsTheUnderlineBack() {
        let storage = underlined(over: NSRange(location: 10, length: 5))
        engine().highlight(storage, in: whole(storage))

        #expect(
            storage.attribute(.underlineStyle, at: 10, effectiveRange: nil) as? Int
                == NSUnderlineStyle.thick.rawValue
        )
        #expect(storage.attribute(.underlineColor, at: 10, effectiveRange: nil) as? NSColor == severity)
    }

    /// The colour of the token underneath still lands, and lands *on top* —
    /// the two passes paint different attributes of the same characters, and
    /// preserving one must not mean skipping the other.
    @Test func theTokenColourIsStillAppliedUnderTheUnderline() {
        let storage = underlined(over: NSRange(location: 10, length: 5))
        engine().highlight(storage, in: whole(storage))

        #expect(
            storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor
                == theme.color(for: .keyword)
        )
    }

    /// The real shape of the bug: `textDidChange` recolours only the region
    /// around the edit, and a squiggle can be wider than it. The part inside
    /// is read and written back, the part outside was never reset, so the
    /// underline comes out whole rather than half-erased.
    @Test func anUnderlineWiderThanTheRecolouredRegionSurvivesWhole() {
        let storage = underlined(over: NSRange(location: 0, length: 19))
        engine().highlight(storage, in: NSRange(location: 10, length: 9))

        for offset in [0, 9, 10, 18] {
            #expect(storage.attribute(.underlineStyle, at: offset, effectiveRange: nil) != nil)
            #expect(storage.attribute(.underlineColor, at: offset, effectiveRange: nil) as? NSColor == severity)
        }
    }

    /// Nothing preserved is the plain reset the engine did before, and it has
    /// to stay reachable: an attribute this pass *does* own — a stale colour
    /// from a comment that stopped being one — must still be cleared.
    @Test func preservingNothingClearsEverything() {
        let storage = underlined(over: NSRange(location: 10, length: 5))
        engine().highlight(storage, in: whole(storage), preserving: [])

        #expect(storage.attribute(.underlineStyle, at: 10, effectiveRange: nil) == nil)
        #expect(storage.attribute(.underlineColor, at: 10, effectiveRange: nil) == nil)
    }

    // MARK: What it costs

    /// Stated as a ratio against the same recolour with nothing to preserve,
    /// because a millisecond budget on a shared runner measures the runner.
    ///
    /// The added work is two enumerations of the region being repainted,
    /// beside a tokenisation of the same region — so the two passes belong in
    /// the same order of magnitude. A ratio this loose still catches the
    /// mistake that matters: reading the attributes off the *document*
    /// instead of the range, which grows with the file rather than the edit.
    ///
    /// Two documents rather than one, because the unpreserved pass erases the
    /// underline it is the baseline for — while the preserved pass puts it
    /// back on every iteration, which is exactly the work being measured.
    @Test func preservingCostsAFractionOfTheRecolour() {
        let text = String(repeating: "let value = compute(a, b) // note\n", count: 2_000)
        let span = NSRange(location: 0, length: 40_000)
        let engine = engine()

        let plain = underlined(text, over: span)
        let squiggled = underlined(text, over: span)
        let region = whole(plain)

        engine.highlight(plain, in: region, preserving: [])

        let bare = elapsed { engine.highlight(plain, in: region, preserving: []) }
        let preserved = elapsed { engine.highlight(squiggled, in: region) }

        #expect(preserved < bare * 3, "\(preserved) against \(bare)")
    }

    private func elapsed(_ body: () -> Void) -> Duration {
        let started = ContinuousClock.now
        for _ in 0..<3 { body() }
        return ContinuousClock.now - started
    }
}

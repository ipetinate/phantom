import AppKit
import Foundation
@testable import Ghostty
import SwiftUI
import Testing

/// Whether a sidebar tab row draws its colour indicator at all.
///
/// `SidebarTabRow` opens its `HStack` with `if let accent =
/// override?.accentColor`, so `TabOverride.accentColor` is the whole
/// decision — and the nil branch is the one that matters visually. An
/// absent view adds no `HStack` spacing, which is what keeps an uncoloured
/// tab's icon exactly where it was before the indicator moved to the front
/// of the row. Anything that made this return a colour for an override
/// carrying none would shift every uncoloured row by 9pt at once, with no
/// bar visible to explain it.
@MainActor
struct SidebarTabColorIndicatorTests {
    @Test func anOverrideWithNoColourDrawsNothing() {
        let override = SidebarGroupStore.TabOverride()
        let accent = override.accentColor
        #expect(accent == nil)
    }

    /// `.none` is a real case of the palette enum, not the absence of one:
    /// it is what the editor writes when the user clears the colour.
    @Test func theNonePaletteCaseDrawsNothing() {
        var override = SidebarGroupStore.TabOverride()
        override.color = TerminalTabColor.none
        let accent = override.accentColor
        #expect(accent == nil)
    }

    @Test func aPaletteColourDrawsTheIndicator() {
        var override = SidebarGroupStore.TabOverride()
        override.color = .teal
        let accent = override.accentColor
        #expect(accent != nil)
    }

    /// The theme swatches and the colour picker both write `colorHex`, and it
    /// outranks the palette case so picking a theme colour over an older
    /// palette one takes effect.
    @Test func aHexColourOutranksThePaletteCase() {
        var override = SidebarGroupStore.TabOverride()
        override.color = .red
        override.colorHex = "#00FF00"
        let accent = override.accentColor
        #expect(accent == Color(nsColor: NSColor(hex: "#00FF00")!))
    }

    /// A hex that cannot be parsed falls back to the palette case rather than
    /// blanking the indicator: a garbled persisted string must not silently
    /// take a row's colour away.
    @Test func anUnparseableHexFallsBackToThePaletteCase() {
        var override = SidebarGroupStore.TabOverride()
        override.color = .green
        override.colorHex = "not-a-colour"
        let accent = override.accentColor
        #expect(accent == TerminalTabColor.green.sidebarAccent)
    }
}

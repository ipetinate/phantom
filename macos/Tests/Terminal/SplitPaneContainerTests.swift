import AppKit
import SwiftUI
@testable import Ghostty
import Testing

/// The arrangement the container keeps, and the one judgement its corner
/// control makes.
///
/// Nothing here renders the view. `SplitPaneContainer` delegates its layout
/// to the window's own `SplitView`, which already has tests of its own, so
/// what is left to check is the state a host persists and the control that
/// changes it.
@MainActor
struct SplitPaneContainerTests {
    @Test func aFreshSplitIsSideBySideAndEven() {
        let model = SplitPaneModel()
        #expect(model.direction == .horizontal)
        #expect(model.split == CGFloat(0.5))
    }

    /// Synchronised scrolling is a decision, not a default. Two features
    /// share this container and they will not agree about it.
    @Test func scrollSyncStartsOff() {
        #expect(!SplitPaneModel().scrollSync.isEnabled)
    }

    @Test func theDirectionTogglesBothWays() {
        let model = SplitPaneModel()

        model.toggleDirection()
        #expect(model.direction == .vertical)

        model.toggleDirection()
        #expect(model.direction == .horizontal)
    }

    /// A share read back from disk never passed through a drag, so it never
    /// met the bound the drag enforces. Left alone, a stored `1.0` gives a
    /// second pane no width at all and a reader no way to notice which
    /// half went missing.
    @Test func aRestoredShareIsBroughtBackInsideThePane() {
        #expect(SplitPaneModel(split: 2).split == CGFloat(0.95))
        #expect(SplitPaneModel(split: -1).split == CGFloat(0.05))
        #expect(SplitPaneModel(split: 0.4).split == CGFloat(0.4))
    }

    @Test func aShareThatIsNotANumberFallsBackToEven() {
        #expect(SplitPaneModel(split: .nan).split == CGFloat(0.5))
        #expect(SplitPaneModel(split: .infinity).split == CGFloat(0.5))
    }

    @Test func assigningAShareClampsItToo() {
        let model = SplitPaneModel()
        model.split = 12
        #expect(model.split == CGFloat(0.95))
    }

    /// The glyph names where the click goes, not where the reader already
    /// is. Side by side offers stacking; stacked offers side by side.
    @Test func theToggleShowsTheArrangementItWillProduce() {
        #expect(SplitPaneDirectionToggle.symbol(for: .horizontal) == "rectangle.split.1x2")
        #expect(SplitPaneDirectionToggle.symbol(for: .vertical) == "rectangle.split.2x1")
    }

    @Test func theToggleSaysWhatItWillDo() {
        #expect(SplitPaneDirectionToggle.help(for: .horizontal) == "Stack Panes")
        #expect(SplitPaneDirectionToggle.help(for: .vertical) == "Place Panes Side by Side")
    }

    /// Both glyphs have to exist, or the control renders as a blank chip on
    /// exactly one of the two directions — the half nobody screenshots.
    @Test func bothGlyphsAreRealSymbols() {
        for direction: SplitViewDirection in [.horizontal, .vertical] {
            let name = SplitPaneDirectionToggle.symbol(for: direction)
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not a system symbol"
            )
        }
    }

    /// A container on its own is complete, and a host that has its own
    /// corner can say so.
    ///
    /// The opt-out exists because two places already want that corner: the
    /// pane's presentation control sits there, and a diff nested inside a
    /// source-and-diff split would otherwise draw a second toggle driving
    /// the very same model.
    @Test func theContainerDrawsItsOwnToggleUnlessAskedNotTo() {
        let model = SplitPaneModel()

        let standalone = SplitPaneContainer(model: model) {
            Color.clear
        } second: {
            Color.clear
        }

        let hosted = SplitPaneContainer(model: model, showsDirectionToggle: false) {
            Color.clear
        } second: {
            Color.clear
        }

        #expect(standalone.showsDirectionToggle)
        #expect(!hosted.showsDirectionToggle)
    }

    /// A host stores the direction across launches, so it has to survive a
    /// round trip through whatever it is stored in.
    @Test func theDirectionSurvivesBeingWrittenDown() throws {
        let encoded = try JSONEncoder().encode(SplitViewDirection.vertical)
        #expect(try JSONDecoder().decode(SplitViewDirection.self, from: encoded) == .vertical)
    }
}

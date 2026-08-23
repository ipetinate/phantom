import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The sidebar width a drag leaves behind, and the reset that drops it.
@MainActor
struct SidebarWidthOverrideTests {
    private func withDefaults(
        seed: [String: Any] = [:],
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let name = "SidebarWidthOverrideTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        for (key, value) in seed {
            defaults.set(value, forKey: key)
        }
        try body(defaults)
    }

    @Test func nothingDraggedYetReadsAsNoOverride() throws {
        try withDefaults { defaults in
            #expect(SidebarWidthOverride.width(in: defaults) == nil)
        }
    }

    @Test func aDraggedWidthIsReadBack() throws {
        try withDefaults(seed: [TerminalController.sidebarWidthDefaultsKey: 320.0]) { defaults in
            #expect(SidebarWidthOverride.width(in: defaults) == 320)
        }
    }

    /// `UserDefaults.double(forKey:)` answers 0 for a key that isn't there,
    /// so a stored 0 has to mean the same thing — which is the reading
    /// `TerminalController.sharedSidebarWidth` already takes.
    @Test func aZeroWidthIsNoOverride() throws {
        try withDefaults(seed: [TerminalController.sidebarWidthDefaultsKey: 0.0]) { defaults in
            #expect(SidebarWidthOverride.width(in: defaults) == nil)
        }
    }

    /// The point of the whole thing: after a reset the configured width is
    /// what windows fall back to, because there is no longer a key to prefer.
    @Test func resettingRemovesTheKeyRatherThanZeroingIt() throws {
        try withDefaults(seed: [TerminalController.sidebarWidthDefaultsKey: 400.0]) { defaults in
            SidebarWidthOverride.clear(in: defaults)

            #expect(SidebarWidthOverride.width(in: defaults) == nil)
            #expect(defaults.object(forKey: TerminalController.sidebarWidthDefaultsKey) == nil)
        }
    }
}

/// The hand-built segmented track: what colour its selected label is, and
/// where the arrow keys take the selection.
struct IconSegmentedControlTests {
    /// It was `Color.white` regardless of what it sat on. Themes with a light
    /// accent — any light theme, and the pastel dark ones — printed white on
    /// near-white, so the selected segment was the unreadable one.
    @Test func theSelectedLabelDarkensOnALightAccent() {
        #expect(IconSegmentedControl.selectedForeground(on: .white) == .black)
        #expect(IconSegmentedControl.selectedForeground(on: NSColor(hex: "#f2d5cf")!) == .black)
    }

    @Test func theSelectedLabelStaysWhiteOnADarkAccent() {
        #expect(IconSegmentedControl.selectedForeground(on: .black) == .white)
        #expect(IconSegmentedControl.selectedForeground(on: NSColor(hex: "#3b78ff")!) == .white)
    }

    @Test func arrowKeysStepThroughTheSegments() {
        let values = ["Default", "Dark", "Clear"]

        #expect(IconSegmentedControl.value(from: "Default", movingBy: 1, in: values) == "Dark")
        #expect(IconSegmentedControl.value(from: "Clear", movingBy: -1, in: values) == "Dark")
    }

    /// Stopping rather than wrapping, like `NSSegmentedControl` — in a track
    /// this short, wrapping reads as the selection jumping the whole way
    /// across rather than moving by one.
    @Test func arrowKeysStopAtTheEnds() {
        let values = ["Default", "Dark", "Clear"]

        #expect(IconSegmentedControl.value(from: "Default", movingBy: -1, in: values) == "Default")
        #expect(IconSegmentedControl.value(from: "Clear", movingBy: 1, in: values) == "Clear")
    }

    /// A selection the segments don't offer — a config holding a value this
    /// build no longer ships — lands on the first segment rather than
    /// swallowing the keypress.
    @Test func anUnknownSelectionLandsOnTheFirstSegment() {
        #expect(
            IconSegmentedControl.value(from: "Tinted", movingBy: 1, in: ["Default", "Dark"])
                == "Default"
        )
    }
}

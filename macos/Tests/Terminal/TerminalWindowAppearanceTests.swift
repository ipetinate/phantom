@testable import Ghostty
import Testing

@MainActor
struct TerminalWindowAppearanceTests {
    /// The blink on restart: a restored window is ordered front without ever
    /// going through `showWindow`, so the appearance pass that used to be
    /// declined for a hidden window left AppKit's `windowBackgroundColor` on
    /// screen for the first frames. A hidden window now resolves to the same
    /// treatment a shown one does — the blur is the only difference, because
    /// the window server ignores it until the window is being shown.
    @Test func hiddenWindowResolvesTheSameTreatmentWithoutTheBlur() {
        let shown = TerminalWindow.backgroundTreatment(
            backgroundOpacity: 0.8,
            isGlassStyle: false,
            isFullscreen: false,
            forceOpaque: false,
            isVisible: true
        )
        let hidden = TerminalWindow.backgroundTreatment(
            backgroundOpacity: 0.8,
            isGlassStyle: false,
            isFullscreen: false,
            forceOpaque: false,
            isVisible: false
        )

        #expect(shown == .transparent(blur: true))
        #expect(hidden == .transparent(blur: false))
    }

    /// Native fullscreen turns the window background gray and shows widgets
    /// through it, so transparency is dropped there whatever the config says —
    /// and it stays dropped for a window that is not on screen yet, which is
    /// how a session with a fullscreen window comes back.
    @Test(arguments: [true, false])
    func fullscreenIsAlwaysOpaque(isVisible: Bool) {
        #expect(TerminalWindow.backgroundTreatment(
            backgroundOpacity: 0.8,
            isGlassStyle: false,
            isFullscreen: true,
            forceOpaque: false,
            isVisible: isVisible
        ) == .opaque)
    }

    /// The per-window opacity override outranks the configured opacity.
    @Test(arguments: [true, false])
    func forcedOpaqueIgnoresTheConfiguredOpacity(isVisible: Bool) {
        #expect(TerminalWindow.backgroundTreatment(
            backgroundOpacity: 0.8,
            isGlassStyle: false,
            isFullscreen: true,
            forceOpaque: true,
            isVisible: isVisible
        ) == .opaque)
    }

    @Test(arguments: [true, false])
    func fullyOpaqueConfigPaintsTheThemeBackground(isVisible: Bool) {
        #expect(TerminalWindow.backgroundTreatment(
            backgroundOpacity: 1,
            isGlassStyle: false,
            isFullscreen: false,
            forceOpaque: false,
            isVisible: isVisible
        ) == .opaque)
    }

    /// Glass draws its own material, so the window still stops painting its
    /// background — but the window-server blur is never requested for it, on
    /// screen or off.
    @Test(arguments: [true, false])
    func glassNeverAsksForTheWindowServerBlur(isVisible: Bool) {
        #expect(TerminalWindow.backgroundTreatment(
            backgroundOpacity: 1,
            isGlassStyle: true,
            isFullscreen: false,
            forceOpaque: false,
            isVisible: isVisible
        ) == .transparent(blur: false))
    }
}

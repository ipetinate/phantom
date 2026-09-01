import AppKit
import SwiftUI

/// The welcome window: one shared instance, opened once by itself and after
/// that only when somebody asks for it.
///
/// Built like `SettingsWindowController` — a programmatic `NSWindow` holding an
/// `NSHostingView`, reused across opens, `isReleasedWhenClosed = false` — and
/// sized like `AboutController`: fixed, because the content is three steps of
/// known height and a resizable welcome is a window somebody has to arrange
/// before they can read it.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to Phantom"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens the window at the first step.
    ///
    /// The hosting view is rebuilt on every open, unlike Settings'. Settings is
    /// a place a reader returns to and expects to find as they left it; this is
    /// a walk-through, and returning to it halfway through somebody else's
    /// session is not a state worth keeping.
    func show() {
        window?.contentView = NSHostingView(
            rootView: WelcomeView(close: { [weak self] in self?.close() }).themedChrome())
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WelcomeShownRecord.markShown()
    }

    /// The launch path. Idempotent, and safe to call from more than one place —
    /// which it is, because the two moments that could be "the app has settled"
    /// are both approximations.
    ///
    /// Not called from `applicationDidFinishLaunching`: the session restore
    /// decides there but presents its windows from async blocks and makes one
    /// key a turn later, so a window opened inline loses focus to it.
    func showOnFirstLaunchIfNeeded() {
        /// A test host must never consume a reader's first launch, and must
        /// never put a window on screen for a suite to trip over — the same
        /// guard the hooks repair and the MCP listener carry.
        guard !MCPServer.isTesting else { return }
        guard WelcomeShownRecord.opensAtLaunch else { return }
        guard window?.isVisible != true else { return }
        show()
    }

    /// Esc closes it, following `AboutController`. A window with one way out
    /// and no keyboard route to it is a window that has to be aimed at.
    @objc func cancel(_ sender: Any?) {
        close()
    }
}

import AppKit
import SwiftUI

/// The settings window: a single shared instance reused across opens,
/// shown in place of opening the raw config file in an editor.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var ghostty: Ghostty.App?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true

        /// The window opens at its own floor, so it can be enlarged but never
        /// shrunk. Deliberate: the widest pane is the shortcut table, which
        /// wraps into unreadability below this. This is the *only* place the
        /// minimum is declared — the panes used to repeat it as SwiftUI
        /// `.frame(minWidth:minHeight:)`, one matching and one smaller and
        /// therefore dead, which read as three different answers.
        window.contentMinSize = NSSize(width: 960, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("GhosttySettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(ghostty: Ghostty.App) {
        if self.ghostty !== ghostty || window?.contentView == nil {
            self.ghostty = ghostty
            window?.contentView = NSHostingView(rootView: SettingsRootView(ghostty: ghostty).themedChrome())
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

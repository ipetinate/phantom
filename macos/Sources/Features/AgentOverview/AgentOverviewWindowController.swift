import AppKit
import SwiftUI

@MainActor
final class AgentOverviewWindowController: NSWindowController {
    static let shared = AgentOverviewWindowController()

    static let minimumSize = NSSize(width: 720, height: 520)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 860, height: 640)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Agents"
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PhantomAgentOverview")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        if window?.contentView == nil {
            window?.contentView = NSHostingView(
                rootView: AgentOverviewView(center: .shared).themedChrome())
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func cancel(_ sender: Any?) {
        close()
    }
}

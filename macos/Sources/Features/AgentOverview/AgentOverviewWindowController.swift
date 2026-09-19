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
        window.title = "Agents Manager"
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
        show(relativeTo: nil)
    }

    func show(relativeTo parent: NSWindow?) {
        if window?.contentView == nil {
            window?.contentView = NSHostingView(
                rootView: AgentOverviewView(center: .shared).themedChrome())
        }
        if let parent, let window {
            let frame = parent.frame
            let size = window.frame.size
            let origin = NSPoint(
                x: frame.maxX - size.width,
                y: frame.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func cancel(_ sender: Any?) {
        close()
    }
}

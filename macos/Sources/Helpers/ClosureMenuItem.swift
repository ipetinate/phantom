import AppKit

/// A menu item that runs a closure.
///
/// `NSMenuItem` wants a target and a selector, and a SwiftUI `View` is a
/// struct with no `@objc` surface to offer as one. Any menu a SwiftUI view
/// pops — the file explorer's rows, the editor's tabs — is built from a
/// description of commands, so the item has to carry its own action.
///
/// Shared rather than repeated: both of those menus exist in two openings, a
/// right-click drawn as SwiftUI buttons and a double click popped as an
/// `NSMenu`, and this is the one piece the AppKit half of each needs.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    /// Never called: nothing archives these menus.
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is built in code, never unarchived")
    }

    @objc private func fire() {
        handler()
    }
}

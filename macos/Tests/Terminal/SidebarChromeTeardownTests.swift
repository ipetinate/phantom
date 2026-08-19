import AppKit
import Testing

/// The ownership rules `TerminalController.releaseSidebarChrome` rests on, one
/// of which is the opposite of what it was written believing.
///
/// `windowWillClose` clears `contentView` so a closing window drops its view
/// tree. What defeats that is the controller holding a **view** — the split
/// view, the chrome, the editor's hosting view — because a view retains its
/// subviews and the terminal's hosting view leads back to the controller.
///
/// A held constraint does **not**: `NSLayoutConstraint` refers to its items
/// weakly, so keeping one alive keeps nothing else alive. That was assumed to
/// be the mechanism and it is not, which is why it is pinned here — the belief
/// is the intuitive one, and the next person to read that release will reach
/// for it again.
///
/// Pinned as rules rather than against the controller because the controller
/// cannot be built without a running libghostty app.
@MainActor
struct SidebarChromeTeardownTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// The belief this fix was written on, shown to be false.
    ///
    /// A constraint holds `firstItem` and `secondItem` weakly, so retaining one
    /// after the window let go of its content view retains nothing. Clearing
    /// the controller's constraint properties is therefore tidiness, not the
    /// repair — the repair is the view references in the same method.
    @Test func aHeldConstraintDoesNotKeepTheTreeAlive() {
        let window = makeWindow()
        var held: NSLayoutConstraint?
        weak var pane: NSView?
        weak var child: NSView?

        autoreleasepool {
            let content = NSView()
            let paneView = NSView()
            let childView = NSView()
            paneView.translatesAutoresizingMaskIntoConstraints = false
            childView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(paneView)
            paneView.addSubview(childView)
            window.contentView = content

            let constraint = childView.topAnchor.constraint(equalTo: paneView.topAnchor)
            constraint.isActive = true

            held = constraint
            pane = paneView
            child = childView
        }

        autoreleasepool { window.contentView = nil }

        #expect(pane == nil, "a retained constraint kept its view alive")
        #expect(child == nil, "a retained constraint kept its view alive")
        #expect(held != nil, "the constraint itself outlives the views it described")
    }

    /// The shape actually measured in a leaked window: the controller holds the
    /// former content view itself, so clearing `contentView` moves the tree
    /// nowhere at all.
    @Test func holdingTheFormerContentViewKeepsTheTreeAlive() {
        let window = makeWindow()
        var held: NSView?
        weak var child: NSView?

        autoreleasepool {
            let content = NSView()
            let childView = NSView()
            content.addSubview(childView)
            window.contentView = content

            held = content
            child = childView
        }

        autoreleasepool { window.contentView = nil }
        #expect(child != nil)

        autoreleasepool { held = nil }
        #expect(child == nil)
    }

    @Test func droppingTheConstraintReleasesTheTree() {
        let window = makeWindow()
        var held: NSLayoutConstraint?
        weak var pane: NSView?
        weak var child: NSView?

        autoreleasepool {
            let content = NSView()
            let paneView = NSView()
            let childView = NSView()
            paneView.translatesAutoresizingMaskIntoConstraints = false
            childView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(paneView)
            paneView.addSubview(childView)
            window.contentView = content

            let constraint = childView.topAnchor.constraint(equalTo: paneView.topAnchor)
            constraint.isActive = true

            held = constraint
            pane = paneView
            child = childView
        }

        autoreleasepool { window.contentView = nil }
        autoreleasepool { held = nil }

        #expect(pane == nil)
        #expect(child == nil)
    }
}

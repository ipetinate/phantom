import AppKit
import SwiftUI

/// Makes the enclosing scroll view use overlay scrollers.
///
/// `.scrollIndicators(.hidden)` is already on the lists in the sidebar and a
/// bar shows anyway, which means the modifier is not reaching the scroller
/// that is drawn. Overlay is the style that appears while scrolling and
/// fades — the behaviour a sidebar wants — and a *legacy* scroller is the
/// one that sits there permanently and takes a column of layout for itself.
/// Setting it on the `NSScrollView` reaches it whatever SwiftUI decided.
///
/// Placed inside the scroll view's content with no size of its own, so it
/// can find its way up to the scroll view and otherwise does nothing.
struct OverlayScrollers: View {
    /// How heavy the bar should read. Defaults to chrome, because every
    /// caller of this view *is* chrome — a tab strip, a tree, a list. The
    /// panes that read as content install their scrollers directly on the
    /// `NSScrollView` they build.
    var weight: ThinScroller.Weight = .chrome

    var body: some View {
        Representable(weight: weight)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Representable: NSViewRepresentable {
        let weight: ThinScroller.Weight

        func makeNSView(context: Context) -> NSView {
            let finder = Finder()
            finder.weight = weight
            return finder
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            (nsView as? Finder)?.weight = weight
            (nsView as? Finder)?.apply()
        }
    }

    private final class Finder: NSView {
        var weight: ThinScroller.Weight = .chrome
        /// Applied on arrival in a window, which is the first moment there is
        /// a scroll view above this to find.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Idempotent: SwiftUI calls `updateNSView` on every pass, and
        /// replacing the scrollers each time would throw away the one
        /// currently mid-fade.
        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            guard !(scrollView.verticalScroller is ThinScroller) else { return }
            scrollView.useThinScrollers(weight: weight)
        }
    }
}

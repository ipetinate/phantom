import AppKit
import Combine
import SwiftUI

/// Which tab is being dragged right now, or nil between drags.
///
/// The end of a drag is the fact the highlight needs and the one SwiftUI's
/// `.onDrag` never gives: a session released over the cell it started in
/// reaches neither `performDrop` nor `dropExited`, so a panel painted on the
/// way there stayed painted. An AppKit session reports `endedAt` for every
/// ending there is, including that one — which is why the drag is built in
/// AppKit at all.
///
/// App-wide rather than per window, because a session is: there is one
/// pointer, so at most one tab is in flight.
@MainActor
final class EditorTabDragSession: ObservableObject {
    static let shared = EditorTabDragSession()

    @Published private(set) var item: EditorCenter.DragItem?

    func begin(_ item: EditorCenter.DragItem) {
        self.item = item
        WindowBreadcrumbs.note("tab drag: began \(EditorTabDrag.text(for: item))")
    }

    func end() {
        guard item != nil else { return }
        item = nil
        WindowBreadcrumbs.note("tab drag: session ended")
    }
}

/// The gesture layer over one tab: click, double click, right click, drag.
///
/// AppKit rather than SwiftUI, and all four together rather than a mix. The
/// terminal's own splits are dragged this way — see `SurfaceDragSource` — and
/// the reason is the operation mask: a session begun by hand answers `.move`
/// for a drag inside the app, which is what lets a destination *propose*
/// `.move`. SwiftUI's `.onDrag` offers a copy, and a destination proposing a
/// move the source never offered has AppKit refuse the drop with no error and
/// no callback.
///
/// Taking the click as well is not incidental. This view has to consume
/// `mouseDown` to keep the window from dragging itself, and a consumed
/// `mouseDown` never reaches SwiftUI — so the tap would be lost. Owning it
/// pays for itself: `clickCount` says whether a click is a double click, so
/// nothing here has to time two clicks and guess.
struct EditorTabDragSource: NSViewRepresentable {
    let item: EditorCenter.DragItem

    /// Called on release without a drag, with AppKit's own click count.
    let onClick: (Int) -> Void

    /// A right click, which opens the same menu a double click does.
    let onMenu: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.item = item
        view.onClick = onClick
        view.onMenu = onMenu
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var item: EditorCenter.DragItem?
        var onClick: ((Int) -> Void)?
        var onMenu: (() -> Void)?

        /// Set while a session this view began is in flight, so the release
        /// that ends it is not also read as a click.
        private var isDragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Consumed deliberately, and not passed to `super`: without this the
        /// window's own drag handler takes over and the reader moves the
        /// window instead of the tab. The click is answered on release.
        override func mouseDown(with event: NSEvent) {
            isDragging = false
        }

        override func mouseUp(with event: NSEvent) {
            guard !isDragging else { return }
            onClick?(event.clickCount)
        }

        override func rightMouseDown(with event: NSEvent) {
            onMenu?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let item else { return }
            guard let pasteboardItem = item.pasteboardItem() else { return }

            let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
            if let image = snapshot() {
                let origin = convert(event.locationInWindow, from: nil)
                dragged.setDraggingFrame(
                    NSRect(
                        x: origin.x - image.size.width / 2,
                        y: origin.y - image.size.height / 2,
                        width: image.size.width,
                        height: image.size.height),
                    contents: image)
            }

            isDragging = true
            EditorTabDragSession.shared.begin(item)

            let session = beginDraggingSession(with: [dragged], event: event, source: self)

            /// Off, so a release outside every cell reports `endedAt` at once
            /// instead of after the tab has flown home. The highlight waits on
            /// that report.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        /// The tab as the reader sees it, for the thing that follows the
        /// pointer. Drawn from the superview because that is where SwiftUI
        /// renders the tab; this view is a transparent layer over it.
        private func snapshot() -> NSImage? {
            guard let superview, bounds.width > 1, bounds.height > 1 else { return nil }
            let rect = convert(bounds, to: superview)
            guard let representation = superview.bitmapImageRepForCachingDisplay(in: rect)
            else { return nil }

            superview.cacheDisplay(in: rect, to: representation)
            let image = NSImage(size: rect.size)
            image.addRepresentation(representation)
            return image
        }

        // MARK: NSDraggingSource

        /// A move inside the app, nothing outside it. This is the answer that
        /// lets a cell propose `.move`, and a tab means nothing to another
        /// application.
        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            EditorTabDragSession.shared.end()
        }
    }
}

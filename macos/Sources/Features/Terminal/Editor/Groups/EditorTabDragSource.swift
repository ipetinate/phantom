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

    /// What the thing following the pointer says. Handed in rather than
    /// derived: the terminal's tab is named by the window's title, which only
    /// the bar knows.
    let label: String

    /// The tab as the reader sees it, rendered by the side that draws it.
    ///
    /// SwiftUI's own renderer, asked for by the tab itself — see
    /// `EditorTabItem.dragPreview`. AppKit cannot produce this: the tab is a
    /// SwiftUI view, and the two ways an `NSView` has of copying what is on
    /// screen both come back empty for one. Nil falls back to a drawn pill.
    let preview: () -> NSImage?

    /// Called on release without a drag, with AppKit's own click count.
    let onClick: (Int) -> Void

    /// A right click, which opens the same menu a double click does.
    let onMenu: () -> Void

    /// Moves the tab along its own strip, and answers how many places it
    /// actually moved.
    ///
    /// The answer matters because the strip refuses some moves: a tab will
    /// not cross the pinned boundary or leave the end of its run. A gesture
    /// that assumed every request landed would drift out of step with the bar
    /// — see `EditorTabGesture.placed`.
    ///
    /// Defaults to moving nothing, for a tab the strip cannot reorder. The
    /// terminal's tab is the one: it is drawn ahead of the files rather than
    /// among them, and it has no path for the strip to move.
    var onReorder: (Int) -> Int = { _ in 0 }

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
        view.label = label
        view.preview = preview
        view.onClick = onClick
        view.onMenu = onMenu
        view.onReorder = onReorder
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var item: EditorCenter.DragItem?
        var label: String = ""
        var preview: (() -> NSImage?)?
        var onClick: ((Int) -> Void)?
        var onMenu: (() -> Void)?
        var onReorder: ((Int) -> Int)?

        /// Set while a session this view began is in flight, so the release
        /// that ends it is not also read as a click.
        private var isDragging = false

        /// Where the button went down, in the window. The gesture is measured
        /// from here rather than from the previous event: a threshold read
        /// against one event's delta is cleared by a slow drag a point at a
        /// time, and a hand that wanders out and back would leave the tab
        /// somewhere other than where it started.
        private var pressedAt: NSPoint?

        /// The decision itself, which lives in a value with no view in it.
        /// Made afresh on every press, because a gesture is one press.
        private var gesture: EditorTabGesture?

        /// Whether this gesture has moved the tab along the strip.
        ///
        /// A release that reordered is not also a click, for two reasons. A
        /// reorder that ended on the second press of a double click would open
        /// the tab's menu over the tab the reader had just put down. And
        /// selecting it would show its file: a reader tidying the strip is
        /// arranging tabs, not choosing one, and the pane they were reading
        /// would change under them.
        private var didReorder = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Consumed deliberately, and not passed to `super`: without this the
        /// window's own drag handler takes over and the reader moves the
        /// window instead of the tab. The click is answered on release.
        override func mouseDown(with event: NSEvent) {
            isDragging = false
            didReorder = false
            pressedAt = event.locationInWindow
            /// One place along the strip is a tab's width, and this view is
            /// what there is to measure it with.
            ///
            /// Over a file's tab it covers the icon and the name but not the
            /// padding or the close control — it is kept off that button on
            /// purpose, see `EditorTabItem` — so it reads about forty points
            /// short and the swap lands a little before the half. Erring
            /// early is the right way to be wrong here: the reader sees the
            /// tab move while they are still pushing, and pushing further
            /// only moves it on. `EditorTabGesture.minimumStep` is the floor
            /// under a tab too narrow to divide.
            gesture = EditorTabGesture(tabWidth: bounds.width)
        }

        override func mouseUp(with event: NSEvent) {
            let reordered = didReorder
            reset()
            guard !isDragging, !reordered else { return }
            onClick?(event.clickCount)
        }

        override func rightMouseDown(with event: NSEvent) {
            onMenu?()
        }

        /// Sideways reorders, up or down detaches, and a movement too small to
        /// be either leaves the click alone. The whole of that decision is
        /// `EditorTabGesture`; what is left here is reading the pointer and
        /// doing as it says.
        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let pressedAt, var gesture = self.gesture else { return }
            defer { self.gesture = gesture }

            let translation = CGSize(
                width: event.locationInWindow.x - pressedAt.x,
                height: event.locationInWindow.y - pressedAt.y)

            switch gesture.update(translation) {
            case .idle:
                return

            case .reorder(let places):
                didReorder = true
                gesture.moved(onReorder?(places) ?? 0)

            case .detach:
                beginDrag(with: event)
            }
        }

        /// Forgets the gesture, so the next press starts its own.
        private func reset() {
            pressedAt = nil
            gesture = nil
            didReorder = false
        }

        /// Hands the tab to AppKit, which is what splits the pane when it
        /// lands. Reached only once the gesture has said the tab is on its
        /// way out of the row.
        private func beginDrag(with event: NSEvent) {
            guard let item else { return }
            guard let pasteboardItem = item.pasteboardItem() else { return }

            let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let image = preview?() ?? Self.image(for: label)
            let origin = convert(event.locationInWindow, from: nil)
            /// Centred on the pointer, which is where macOS puts a dragged
            /// tab of its own.
            dragged.setDraggingFrame(
                NSRect(
                    x: origin.x - image.size.width / 2,
                    y: origin.y - image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height),
                contents: image)

            isDragging = true
            EditorTabDragSession.shared.begin(item)

            let session = beginDraggingSession(with: [dragged], event: event, source: self)

            /// Off, so a release outside every cell reports `endedAt` at once
            /// instead of after the tab has flown home. The highlight waits on
            /// that report.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        /// The fallback for a preview that could not be rendered: a small
        /// pill naming the tab.
        ///
        /// Snapshotting the tab was the first attempt — `cacheDisplay` on the
        /// superview, which is where SwiftUI renders it — and it produced an
        /// empty image every time, so the drag had no visible payload at all.
        /// SwiftUI draws through a layer tree `cacheDisplay` does not reach.
        ///
        /// This is drawn by hand and so cannot come out blank, which is why it
        /// is the floor under `ImageRenderer` rather than a second attempt at
        /// the same job: the one part of this gesture the reader watches the
        /// whole time must never be invisible.
        static func image(for label: String) -> NSImage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]

            let text = label.isEmpty ? "Tab" : label
            let measured = (text as NSString).size(withAttributes: attributes)
            /// Capped, because a tab's name can be a whole path and a pill as
            /// wide as the window tells the reader nothing about where it is.
            let size = NSSize(
                width: min(measured.width, 260) + 20,
                height: measured.height + 12)

            let image = NSImage(size: size)
            image.lockFocus()

            let border = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let pill = NSBezierPath(roundedRect: border, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
            pill.fill()
            NSColor.separatorColor.setStroke()
            pill.stroke()

            (text as NSString).draw(
                in: NSRect(x: 10, y: 6, width: size.width - 20, height: measured.height),
                withAttributes: attributes)

            image.unlockFocus()
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
            reset()
            EditorTabDragSession.shared.end()
        }
    }
}

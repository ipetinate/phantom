import AppKit
import SwiftUI

/// The image, fitted to the pane it is given unless the reader has asked for a
/// size.
///
/// `NSImageView` rather than SwiftUI's `Image(nsImage:)` for one behaviour that
/// is a property here and awkward there: `animates`, which makes a GIF move. An
/// animation that holds still reads as a broken file.
struct ImageViewerView: NSViewRepresentable {
    let image: NSImage
    let level: MediaZoom.Level
    let onZoomStep: (Int) -> Void

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.image = image
        view.level = level
        view.onZoomStep = onZoomStep
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.image = image
        view.level = level
        view.onZoomStep = onZoomStep
    }

    /// The proposal, never the image's size.
    ///
    /// This is the fix for the bug that took the window off the edge of the
    /// screen: without it SwiftUI asks the view how big it would like to be,
    /// `NSImageView` answers with the size of the image, and a 2048-pixel
    /// screenshot became a 2048-point pane that dragged the window out with it.
    /// An unspecified or infinite dimension falls back to something small, so
    /// the parent's frame is what decides — an infinite answer here would put
    /// the same bug back in a different place.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ImageCanvasView,
        context: Context
    ) -> CGSize? {
        CGSize(width: MediaPaneMetrics.finite(proposal.width),
               height: MediaPaneMetrics.finite(proposal.height))
    }
}

/// Scrolls only when the reader has zoomed past what fits, and centres the
/// image the rest of the time.
///
/// The centring is why there is a container between the scroll view and the
/// image: a document view exactly the size of a small image sits in the corner,
/// while one grown to the size of the viewport can hold it in the middle. And
/// because the container is never smaller than the viewport, "does this scroll"
/// answers itself — the scrollers auto-hide when there is nothing to reach.
final class ImageCanvasView: NSView {
    private let scrollView = ZoomingScrollView()
    private let container = NSView()
    private let imageView = NSImageView()

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            needsLayout = true
        }
    }

    var level: MediaZoom.Level = MediaZoom.fit {
        didSet {
            guard level != oldValue else { return }
            needsLayout = true
        }
    }

    var onZoomStep: ((Int) -> Void)? {
        didSet { scrollView.onZoomStep = onZoomStep }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        /// Proportionally, not axes-independently: the frame is computed with
        /// the image's aspect already in it, and rounding it to whole points
        /// can leave the two off by a fraction. Letterboxing by half a point is
        /// invisible; a stretched image is not.
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true

        container.addSubview(imageView)
        scrollView.documentView = container
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.useThinScrollers()
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Nothing, deliberately. The one thing this view must never do is ask for
    /// room of its own.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        let available = bounds.size
        guard let size = image?.size, size.width > 0, size.height > 0 else {
            container.frame = NSRect(origin: .zero, size: available)
            imageView.frame = .zero
            return
        }

        let display = MediaZoom.displaySize(image: size, available: available, level: level)
        let canvas = MediaZoom.canvasSize(image: size, available: available, level: level)

        container.frame = NSRect(origin: .zero, size: canvas)
        imageView.frame = NSRect(
            x: ((canvas.width - display.width) / 2).rounded(),
            y: ((canvas.height - display.height) / 2).rounded(),
            width: display.width.rounded(),
            height: display.height.rounded())
    }
}

/// A scroll view that hands ⌘+scroll to the zoom instead of scrolling.
///
/// Subclassed rather than handled further out because `NSScrollView` *consumes*
/// scroll events: they never reach the responder chain above it, so an override
/// on the containing view would simply never be called.
final class ZoomingScrollView: NSScrollView {
    var onZoomStep: ((Int) -> Void)?

    private var accumulated: CGFloat = 0

    /// One gesture on a trackpad arrives as a stream of small deltas, so they
    /// are added up and a step taken when they cross a threshold — taking one
    /// per event would cross the whole ladder on a single flick.
    private static let step: CGFloat = 12

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onZoomStep else {
            super.scrollWheel(with: event)
            return
        }

        accumulated += event.scrollingDeltaY
        if abs(accumulated) >= Self.step {
            onZoomStep(accumulated > 0 ? 1 : -1)
            accumulated = 0
        }

        /// Left over from a gesture that stopped short of a step, which would
        /// otherwise be added to the *next* one and make it arrive early.
        if event.phase == .ended || event.momentumPhase == .ended {
            accumulated = 0
        }
    }
}

/// Shared measurements and the one guard both viewers need.
enum MediaPaneMetrics {
    /// The rail of page thumbnails takes the strip the code minimap would
    /// have, reading the minimap's own constant so the two cannot drift apart.
    static var railWidth: CGFloat { CodeTextView.minimapColumnWidth }

    /// A proposal SwiftUI has not decided yet, or has decided is unbounded, is
    /// no basis for a frame — answering it with infinity is the resizing bug
    /// again in a different place.
    static func finite(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return 1 }
        return value
    }
}

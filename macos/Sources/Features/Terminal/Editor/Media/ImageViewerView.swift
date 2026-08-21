import AppKit
import SwiftUI

/// The image, fitted to the pane it is given and never larger.
///
/// `NSImageView` rather than SwiftUI's `Image(nsImage:)` for one behaviour that
/// is a property here and awkward there: `animates`, which makes a GIF move. An
/// animation that holds still reads as a broken file.
struct ImageViewerView: NSViewRepresentable {
    let image: NSImage
    let zoom: CGFloat

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.image = image
        view.zoom = zoom
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.image = image
        view.zoom = zoom
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
        CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }

    private func finite(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return 1 }
        return value
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
    private let scrollView = NSScrollView()
    private let container = NSView()
    private let imageView = NSImageView()

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            needsLayout = true
        }
    }

    var zoom: CGFloat = MediaZoom.fit {
        didSet {
            guard zoom != oldValue else { return }
            needsLayout = true
        }
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

        let display = MediaZoom.displaySize(image: size, available: available, zoom: zoom)
        let canvas = MediaZoom.canvasSize(image: size, available: available, zoom: zoom)

        container.frame = NSRect(origin: .zero, size: canvas)
        imageView.frame = NSRect(
            x: ((canvas.width - display.width) / 2).rounded(),
            y: ((canvas.height - display.height) / 2).rounded(),
            width: display.width.rounded(),
            height: display.height.rounded())
    }
}

import AppKit
import PDFKit
import SwiftUI

/// A PDF: the pages, and a rail of thumbnails down the side.
///
/// One representable rather than two side by side, because `PDFThumbnailView`
/// works by holding a reference to the `PDFView` it belongs to — and two
/// SwiftUI representables cannot hand each other the views they made.
///
/// Not inverted for dark mode. A white page beside dark code is jarring but
/// correct; inverting wrecks every figure and photograph on it.
struct PDFViewerView: NSViewRepresentable {
    let document: PDFDocument
    let background: NSColor
    let level: MediaZoom.Level
    let onZoomStep: (Int) -> Void
    var onZoomScale: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> PDFPaneView {
        let view = PDFPaneView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: PDFPaneView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: PDFPaneView) {
        view.onZoomStep = onZoomStep
        view.onZoomScale = onZoomScale
        view.background = background
        view.show(document)
        view.apply(level)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PDFPaneView,
        context: Context
    ) -> CGSize? {
        CGSize(width: MediaPaneMetrics.finite(proposal.width),
               height: MediaPaneMetrics.finite(proposal.height))
    }
}

/// `PDFView` handles paging, selection and rendering, and renders pages lazily
/// — which is why a large PDF costs the view rather than the document.
final class PDFPaneView: NSView {
    private let pdfView = ZoomingPDFView()
    private let thumbnails = PDFThumbnailView()

    var onZoomStep: ((Int) -> Void)? {
        didSet { pdfView.onZoomStep = onZoomStep }
    }

    var onZoomScale: ((CGFloat) -> Void)? {
        didSet { pdfView.onZoomScale = onZoomScale }
    }

    var background: NSColor = .textBackgroundColor {
        didSet {
            guard background != oldValue else { return }
            pdfView.backgroundColor = background
            thumbnails.backgroundColor = background
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = false
        pdfView.autoScales = true

        /// One column, and a thumbnail narrow enough to sit in the minimap's
        /// strip with room for the highlight around the current page.
        thumbnails.pdfView = pdfView
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.thumbnailSize = NSSize(width: 52, height: 68)

        addSubview(pdfView)
        addSubview(thumbnails)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func show(_ document: PDFDocument) {
        guard pdfView.document !== document else { return }
        pdfView.document = document
        needsLayout = true
    }

    /// `autoScales` and an explicit `scaleFactor` are the same setting seen from
    /// two ends — assigning the factor turns auto-scaling off — so one is set or
    /// the other, never both.
    ///
    /// A scale here is absolute, and that falls out for free: `PDFView`'s own
    /// `scaleFactor` already means "this much of the page's natural size", which
    /// is the same thing 100% means for an image.
    func apply(_ level: MediaZoom.Level) {
        switch level {
        case .fit:
            pdfView.autoScales = true
        case .scale(let scale):
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
        }
    }

    /// A rail for a document with pages to move between. A single page has
    /// nowhere to go, and a strip of one thumbnail is just a narrower pane.
    private var showsRail: Bool {
        (pdfView.document?.pageCount ?? 0) > 1
    }

    override func layout() {
        super.layout()

        let rail = showsRail ? MediaPaneMetrics.railWidth : 0
        thumbnails.isHidden = !showsRail

        pdfView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - rail), height: bounds.height)
        thumbnails.frame = NSRect(
            x: bounds.width - rail, y: 0, width: rail, height: bounds.height)
    }
}

/// ⌘+scroll zooms rather than scrolls, the same as it does over an image.
///
/// `PDFView` consumes scroll events for its own scrolling, so this has to be
/// the class that sees them first.
final class ZoomingPDFView: PDFView {
    var onZoomStep: ((Int) -> Void)?
    var onZoomScale: ((CGFloat) -> Void)?

    /// The pinch. `PDFView` would handle this itself, and letting it would
    /// fork the truth: its internal scale would move while the level this
    /// pane holds — and the readout drawn from it — stayed put.
    override func magnify(with event: NSEvent) {
        guard let onZoomScale else {
            super.magnify(with: event)
            return
        }
        onZoomScale(1 + event.magnification)
    }

    private var accumulated: CGFloat = 0
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
        if event.phase == .ended || event.momentumPhase == .ended {
            accumulated = 0
        }
    }
}

import AppKit
import PDFKit
import SwiftUI

/// A PDF, scrolling continuously.
///
/// `PDFView` handles paging, selection and rendering, and renders pages lazily
/// — which is why a large PDF costs the view rather than the document.
///
/// Not inverted for dark mode. A white page beside dark code is jarring but
/// correct; inverting wrecks every figure and photograph on it.
struct PDFViewerView: NSViewRepresentable {
    let document: PDFDocument
    let background: NSColor
    let zoom: CGFloat

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = false
        view.backgroundColor = background
        view.document = document
        view.autoScales = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.backgroundColor = background

        /// `autoScales` and an explicit `scaleFactor` are the same setting seen
        /// from two ends — assigning the factor turns auto-scaling off — so
        /// they are set one or the other, never both. At rest the page fits;
        /// zoomed, it is a multiple of whatever fitting would have been, so
        /// the same ladder means the same thing here as it does for an image.
        if abs(zoom - MediaZoom.fit) < 0.001 {
            view.autoScales = true
        } else {
            view.autoScales = false
            let fitting = view.scaleFactorForSizeToFit
            if fitting > 0 { view.scaleFactor = fitting * zoom }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PDFView,
        context: Context
    ) -> CGSize? {
        CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }

    private func finite(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return 1 }
        return value
    }
}

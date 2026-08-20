import AppKit
import PDFKit
import SwiftUI

/// A PDF, scrolling continuously.
struct PDFViewerView: View {
    let url: URL
    let background: NSColor

    @State private var document: PDFDocument?
    @State private var attempted = false

    var body: some View {
        Group {
            if let document {
                PDFPaneView(document: document, background: background)
            } else if attempted {
                MediaUnreadableView(message: "Couldn't read this PDF. It may be encrypted.")
            } else {
                Color.clear
            }
        }
        .onAppear {
            document = PDFDocument(url: url)
            attempted = true
        }
    }
}

/// `PDFView` handles paging, scrolling and text selection, and pages lazily —
/// which is why a large PDF costs the view rather than the document.
///
/// Not inverted for dark mode. A white page beside dark code is jarring but
/// correct; inverting wrecks every figure and photograph on it.
private struct PDFPaneView: NSViewRepresentable {
    let document: PDFDocument
    let background: NSColor

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = false
        view.backgroundColor = background
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.backgroundColor = background
    }
}

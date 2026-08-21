import AppKit
import PDFKit
import SwiftUI

/// The pane a media tab draws: the editor's own background, the viewer, and the
/// two pieces of chrome around it.
///
/// Outside `Editor/Engine/` deliberately — `PDFKit` is not in the import set
/// that `EditorEngineBoundaryTests` allows the engine, and the Markdown preview
/// sits out here for the same reason.
///
/// The file is loaded here rather than in `MediaDocument` so the document stays
/// a decision and the view is the thing that touches the disk. It also puts the
/// failure where it reads best — in the pane, not in an alert that would offer
/// to open the file in another app that is going to fail on it too.
struct MediaPaneView: View {
    let document: MediaDocument
    let theme: CodeTheme

    @State private var image: NSImage?
    @State private var pdf: PDFDocument?
    @State private var bytes: Int?
    @State private var zoom: CGFloat = MediaZoom.fit
    @State private var attempted = false

    var body: some View {
        ZStack {
            Color(nsColor: theme.background)

            /// The pane's own size, read rather than stored: the scale in the
            /// corner is a fact about how big the image is *here*, and holding
            /// it in state would mean a size and a readout that can disagree.
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    viewer(in: proxy.size)

                    if canZoom {
                        MediaZoomControl(zoom: $zoom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    MediaInfoBar(text: info(in: proxy.size))
                }
            }
        }
        /// Belt to the `sizeThatFits` braces. Nothing inside here may change
        /// the size of the pane, whatever it thinks of itself.
        .clipped()
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func viewer(in available: CGSize) -> some View {
        switch document.kind {
        case .image:
            if let image {
                ImageViewerView(image: image, zoom: zoom)
                    .frame(width: available.width, height: available.height)
            } else if attempted {
                unreadable("Couldn't read this image.")
            } else {
                Color.clear
            }

        case .pdf:
            if let pdf {
                PDFViewerView(document: pdf, background: theme.background, zoom: zoom)
                    .frame(width: available.width, height: available.height)
            } else if attempted {
                unreadable("Couldn't read this PDF. It may be encrypted.")
            } else {
                Color.clear
            }
        }
    }

    private func unreadable(_ message: String) -> some View {
        MediaUnreadableView(message: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only once something is on screen to zoom. Buttons that act on nothing
    /// are worse than an empty corner.
    private var canZoom: Bool {
        image != nil || pdf != nil
    }

    private func load() {
        switch document.kind {
        case .image: image = NSImage(contentsOf: document.url)
        case .pdf: pdf = PDFDocument(url: document.url)
        }
        bytes = try? document.url
            .resourceValues(forKeys: [.fileSizeKey]).fileSize
        attempted = true
    }

    /// The line in the bottom corner.
    ///
    /// The resolution comes from the bitmap rather than from `NSImage.size`,
    /// which is in points — for a file carrying a DPI those two differ, and the
    /// honest answer to "what resolution is this" is the pixels it has.
    ///
    /// The percentage is only offered for an image, where it can be computed
    /// from sizes this view already knows. `PDFView` holds its own scale and
    /// reading it back out would mean writing state during a layout pass, so a
    /// PDF says what it is and how many pages, and nothing it cannot stand
    /// behind.
    private func info(in available: CGSize) -> String {
        let format = (document.url.pathExtension as NSString).uppercased

        switch document.kind {
        case .image:
            guard let image else { return MediaInfo.line(format: format, bytes: bytes) }
            let representation = image.representations.first
            let pixels = representation.map {
                CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
            }
            return MediaInfo.line(
                format: format,
                pixels: pixels ?? image.size,
                bytes: bytes,
                scale: MediaZoom.scale(image: image.size, available: available, zoom: zoom))

        case .pdf:
            return MediaInfo.line(format: format, bytes: bytes, pages: pdf?.pageCount)
        }
    }
}

/// Zoom out, zoom in, and back to fitting — in the corner the presentation
/// control uses, because that is where this window keeps the controls that act
/// on how a file is being shown.
struct MediaZoomControl: View {
    @Binding var zoom: CGFloat

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 1) {
            button("minus.magnifyingglass", "Zoom Out", enabled: MediaZoom.canZoomOut(zoom)) {
                zoom = MediaZoom.zoomedOut(from: zoom)
            }
            button("plus.magnifyingglass", "Zoom In", enabled: MediaZoom.canZoomIn(zoom)) {
                zoom = MediaZoom.zoomedIn(from: zoom)
            }
            button(
                "arrow.down.forward.and.arrow.up.backward",
                "Fit to Pane",
                enabled: zoom != MediaZoom.fit
            ) {
                zoom = MediaZoom.fit
            }
        }
        .padding(4)
        .editorOverlayChrome(isHovered: isHovered)
        .opacity(isHovered ? 1 : 0.78)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .padding(6)
    }

    private func button(
        _ symbol: String,
        _ name: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .help(name)
        .accessibilityLabel(name)
    }
}

/// What the file is, in the bottom corner, faint.
///
/// Quieter than the zoom control on purpose: that one is a thing to press and
/// this one is a thing to glance at, so it takes the same material at a lower
/// opacity and never brightens.
struct MediaInfoBar: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .editorOverlayChrome(isHovered: false)
                .opacity(0.72)
                .padding(6)
        }
    }
}

/// What a viewer says when the bytes are not what the name promised.
struct MediaUnreadableView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
    }
}

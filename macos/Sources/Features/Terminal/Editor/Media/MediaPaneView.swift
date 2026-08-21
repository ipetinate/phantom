import AppKit
import PDFKit
import SwiftUI

/// The pane a media tab draws: the editor's own background, the viewer, and the
/// chrome around it.
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
    @State private var level: MediaZoom.Level = MediaZoom.fit
    @State private var attempted = false

    var body: some View {
        ZStack {
            Color(nsColor: theme.background)

            /// The pane's own size, read rather than stored: what "fit" means
            /// is a fact about how much room there is *now*, and holding it in
            /// state would mean a size and a readout that can disagree.
            GeometryReader { proxy in
                let available = viewerSize(in: proxy.size)

                ZStack(alignment: .topTrailing) {
                    viewer(in: proxy.size, available: available)

                    if isLoaded {
                        zoomControl(in: available)
                            .padding(.trailing, chromeInset)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    MediaInfoBar(text: info(in: available))
                        .padding(.trailing, chromeInset)
                }
            }
        }
        /// Belt to the `sizeThatFits` braces. Nothing inside here may change
        /// the size of the pane, whatever it thinks of itself.
        .clipped()
        .onAppear(perform: load)
    }

    // MARK: The viewer

    @ViewBuilder
    private func viewer(in pane: CGSize, available: CGSize) -> some View {
        switch document.kind {
        case .image:
            if let image {
                ImageViewerView(
                    image: image,
                    level: level,
                    onZoomStep: { step($0, in: available) })
                    .frame(width: pane.width, height: pane.height)
            } else if attempted {
                unreadable("Couldn't read this image.")
            } else {
                Color.clear
            }

        case .pdf:
            if let pdf {
                PDFViewerView(
                    document: pdf,
                    background: theme.background,
                    level: level,
                    onZoomStep: { step($0, in: available) })
                    .frame(width: pane.width, height: pane.height)
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

    private var isLoaded: Bool { image != nil || pdf != nil }

    private func load() {
        switch document.kind {
        case .image: image = NSImage(contentsOf: document.url)
        case .pdf: pdf = PDFDocument(url: document.url)
        }
        bytes = try? document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        attempted = true
    }

    // MARK: Zoom

    /// The size the *viewer* has, which is not the size of the pane once a rail
    /// has taken a strip of it — and fitting measured against the wrong one is
    /// off by the width of the rail.
    private func viewerSize(in pane: CGSize) -> CGSize {
        CGSize(width: max(0, pane.width - railWidth), height: pane.height)
    }

    private var railWidth: CGFloat {
        guard document.kind == .pdf, let pages = pdf?.pageCount, pages > 1 else { return 0 }
        return MediaPaneMetrics.railWidth
    }

    /// Clear of the rail and of the scroller, the same two things the editor's
    /// own control has to clear.
    private var chromeInset: CGFloat {
        railWidth + ThinScroller.trackWidth
    }

    /// What is being scaled: the image, or a PDF's first page — whose size in
    /// points is what `PDFView`'s own scale factor is a proportion of, so the
    /// same arithmetic answers for both.
    private var subjectSize: CGSize {
        switch document.kind {
        case .image: return image?.size ?? .zero
        case .pdf: return pdf?.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        }
    }

    private func zoomControl(in available: CGSize) -> some View {
        let subject = subjectSize

        return MediaZoomControl(
            canZoomIn: MediaZoom.canZoomIn(level, image: subject, available: available),
            canZoomOut: MediaZoom.canZoomOut(level, image: subject, available: available),
            isFitted: level == .fit,
            zoomIn: { level = MediaZoom.zoomedIn(from: level, image: subject, available: available) },
            zoomOut: { level = MediaZoom.zoomedOut(from: level, image: subject, available: available) },
            fit: { level = MediaZoom.fit })
    }

    /// One step of ⌘+scroll.
    ///
    /// The size arrives captured in the closure rather than held in state: the
    /// closure is rebuilt on every layout pass, so it always carries the
    /// current one, and storing it would mean writing state from inside a
    /// layout. It goes through the same ladder as the buttons, so a scroll and
    /// a press cannot disagree about what a step is.
    private func step(_ direction: Int, in available: CGSize) {
        let subject = subjectSize
        level = direction > 0
            ? MediaZoom.zoomedIn(from: level, image: subject, available: available)
            : MediaZoom.zoomedOut(from: level, image: subject, available: available)
    }

    // MARK: The readout

    /// The line in the bottom corner.
    ///
    /// The resolution comes from the bitmap rather than from `NSImage.size`,
    /// which is in points — for a file carrying a DPI those differ, and the
    /// honest answer to "what resolution is this" is the pixels it has.
    ///
    /// An image reports the percentage it is drawn at even when fitted, because
    /// that number is computed here and is exact. A **fitted** PDF says "Fit"
    /// instead: `PDFView` works out its own fitting, with its own margins, and
    /// a percentage I calculated separately would be close but not true. Once a
    /// scale is asked for they agree again, because then it is the number that
    /// was set.
    private func info(in available: CGSize) -> String {
        let format = (document.url.pathExtension as NSString).uppercased

        switch document.kind {
        case .image:
            guard let image else { return MediaInfo.line(format: format, bytes: bytes) }
            let pixels = image.representations.first.map {
                CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
            }
            return MediaInfo.line(
                format: format,
                pixels: pixels ?? image.size,
                bytes: bytes,
                scale: MediaZoom.scale(level, image: image.size, available: available))

        case .pdf:
            var scale: CGFloat?
            if case .scale(let asked) = level { scale = asked }
            return MediaInfo.line(
                format: format,
                bytes: bytes,
                pages: pdf?.pageCount,
                scale: scale,
                fitted: level == .fit)
        }
    }
}

/// Zoom out, zoom in, and back to fitting — in the corner the presentation
/// control uses, because that is where this window keeps the controls that act
/// on how a file is being shown.
struct MediaZoomControl: View {
    let canZoomIn: Bool
    let canZoomOut: Bool
    let isFitted: Bool
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let fit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 1) {
            button("minus.magnifyingglass", "Zoom Out", enabled: canZoomOut, action: zoomOut)
            button("plus.magnifyingglass", "Zoom In", enabled: canZoomIn, action: zoomIn)
            button(
                "arrow.down.forward.and.arrow.up.backward",
                "Fit to Pane",
                enabled: !isFitted,
                action: fit)
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

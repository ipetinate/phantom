import Foundation

/// How big to draw a media file, and what the zoom buttons do.
///
/// Pure, because this is where the bug was. `NSImageView` reports the image's
/// own size as its intrinsic content size, SwiftUI takes that for the ideal
/// size, and with nothing constraining it the pane grew to 2048 points and
/// **took the window past the edge of the screen with it** — at which point
/// `scaleProportionallyDown` had nothing to do, since the frame it was asked
/// to fit into was already the size of the image. Deciding the size here, from
/// two sizes and a number, is what makes that arithmetic something a test can
/// hold still.
enum MediaZoom {
    /// Everything visible, which is where a file opens.
    static let fit: CGFloat = 1

    /// Fixed stops rather than a multiplier, so the button is predictable and
    /// two presses in and two out land back exactly where they started.
    static let ladder: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    static func zoomedIn(from zoom: CGFloat) -> CGFloat {
        ladder.first { $0 > zoom + tolerance } ?? ladder[ladder.count - 1]
    }

    static func zoomedOut(from zoom: CGFloat) -> CGFloat {
        ladder.last { $0 < zoom - tolerance } ?? ladder[0]
    }

    static func canZoomIn(_ zoom: CGFloat) -> Bool { zoom < ladder[ladder.count - 1] - tolerance }
    static func canZoomOut(_ zoom: CGFloat) -> Bool { zoom > ladder[0] + tolerance }

    /// How much of its true size the image is being drawn at.
    ///
    /// At `fit` this is the scale that makes it all visible — **capped at 1**,
    /// so a 16-point favicon is drawn at 16 points instead of being blown up
    /// into a blurry wall. Zoom multiplies that.
    static func scale(image: CGSize, available: CGSize, zoom: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0,
              available.width > 0, available.height > 0
        else { return zoom }

        let fitting = min(available.width / image.width, available.height / image.height)
        return min(1, fitting) * zoom
    }

    /// The frame to draw the image in. Never larger than the image times the
    /// zoom, and at `fit` never larger than what it has to sit in.
    static func displaySize(image: CGSize, available: CGSize, zoom: CGFloat) -> CGSize {
        let scale = scale(image: image, available: available, zoom: zoom)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// What the reader is scrolling around inside: the display size, or the
    /// space available where the image is smaller than it — which is what
    /// centres a small image instead of pinning it to a corner.
    static func canvasSize(image: CGSize, available: CGSize, zoom: CGFloat) -> CGSize {
        let display = displaySize(image: image, available: available, zoom: zoom)
        return CGSize(
            width: max(display.width, available.width),
            height: max(display.height, available.height))
    }

    /// Comparing floating point stops for equality is how a button ends up
    /// permanently disabled one stop from the end.
    private static let tolerance: CGFloat = 0.001
}

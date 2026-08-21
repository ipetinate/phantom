import Foundation

/// How big to draw a media file, and what the zoom controls do.
///
/// Pure, because this is where the bug was. `NSImageView` reports the image's
/// own size as its intrinsic content size, SwiftUI took that for the ideal
/// size, and with nothing constraining it a 2048-pixel screenshot became a
/// 2048-point pane that dragged the window out past the edge of the screen — at
/// which point `scaleProportionallyDown` had nothing to do, since the frame it
/// was asked to fit into was already the size of the image. Deciding the size
/// here, from two sizes and a level, is what makes that arithmetic something a
/// test can hold still.
enum MediaZoom {
    /// What the reader has asked for.
    ///
    /// Two cases rather than one number, because "fit" and "some percentage"
    /// are different requests: fitting has to be recomputed when the pane
    /// changes size and a percentage must not be. Collapsing them into a
    /// multiplier of whatever fitting happened to give — which is what this
    /// was first — means the reader can never ask for 1:1, and 100% is the one
    /// number anybody looking at an image actually wants.
    enum Level: Equatable, Sendable {
        case fit
        case scale(CGFloat)
    }

    /// Where a file opens.
    static let fit = Level.fit

    /// Ten percent to eight hundred. The floor is where a very large image
    /// stops being an image, and the ceiling is where a pixel becomes a
    /// hundred-point square — past either, the control is offering to do
    /// something nobody wants.
    static let minimum: CGFloat = 0.1
    static let maximum: CGFloat = 8

    /// Absolute stops, so a press means the same thing in every file: 100% is
    /// the original size, and two presses in and two out land back exactly
    /// where they started, which a multiplier does not guarantee once
    /// floating point is involved. The stops around 1 are the familiar
    /// thirds, so a photo can be halved and doubled without arriving at 49%.
    static let ladder: [CGFloat] = [0.1, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 1.5, 2, 3, 4, 6, 8]

    /// How much of its true size the file is being drawn at.
    ///
    /// Fitting is **capped at 1**, so opening a 16-point favicon shows sixteen
    /// points rather than blowing it up into a blurry wall. Asking for a
    /// percentage is not capped: 400% of a favicon is exactly what somebody
    /// pressing zoom four times wants.
    static func scale(_ level: Level, image: CGSize, available: CGSize) -> CGFloat {
        switch level {
        case .scale(let scale):
            return clamped(scale)

        case .fit:
            guard image.width > 0, image.height > 0,
                  available.width > 0, available.height > 0
            else { return 1 }

            let fitting = min(available.width / image.width, available.height / image.height)
            return min(1, fitting)
        }
    }

    /// The next stop above where the file is being drawn now.
    ///
    /// Measured from the *current scale* rather than from the previous stop,
    /// which is what lets fitting sit between two of them: a large image
    /// fitted at 29% zooms in to a third, not to 100%.
    static func zoomedIn(from level: Level, image: CGSize, available: CGSize) -> Level {
        let current = scale(level, image: image, available: available)
        let next = ladder.first { $0 > current + tolerance } ?? maximum
        return .scale(clamped(next))
    }

    static func zoomedOut(from level: Level, image: CGSize, available: CGSize) -> Level {
        let current = scale(level, image: image, available: available)
        let previous = ladder.last { $0 < current - tolerance } ?? minimum
        return .scale(clamped(previous))
    }

    static func canZoomIn(_ level: Level, image: CGSize, available: CGSize) -> Bool {
        scale(level, image: image, available: available) < maximum - tolerance
    }

    static func canZoomOut(_ level: Level, image: CGSize, available: CGSize) -> Bool {
        scale(level, image: image, available: available) > minimum + tolerance
    }

    /// The frame to draw the image in. At `fit`, never larger than the space
    /// it has to sit in — which is the property the window-resizing bug
    /// violated.
    static func displaySize(image: CGSize, available: CGSize, level: Level) -> CGSize {
        let scale = scale(level, image: image, available: available)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// What the reader pans around inside: the display size, or the space
    /// available where the image is smaller than it — which is what centres a
    /// small image instead of pinning it to a corner.
    static func canvasSize(image: CGSize, available: CGSize, level: Level) -> CGSize {
        let display = displaySize(image: image, available: available, level: level)
        return CGSize(
            width: max(display.width, available.width),
            height: max(display.height, available.height))
    }

    private static func clamped(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(maximum, max(minimum, scale))
    }

    /// Comparing floating point stops for equality is how a button ends up
    /// permanently disabled one stop from the end.
    private static let tolerance: CGFloat = 0.001
}

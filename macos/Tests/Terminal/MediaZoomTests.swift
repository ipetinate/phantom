import AppKit
import Foundation
@testable import Ghostty
import Testing

/// How big a media file is drawn, which is where the window-resizing bug was.
struct MediaZoomTests {
    private let pane = CGSize(width: 800, height: 600)

    /// The regression, stated as the property that was violated: at rest,
    /// nothing is ever asked to be bigger than the space it has. This is what
    /// took the app's window past the edge of the screen.
    @Test func atRestNothingIsEverLargerThanThePane() {
        let images: [CGSize] = [
            CGSize(width: 2048, height: 2048),
            CGSize(width: 4000, height: 900),
            CGSize(width: 900, height: 4000),
            CGSize(width: 16, height: 16),
            CGSize(width: 801, height: 601),
        ]

        for image in images {
            let display = MediaZoom.displaySize(image: image, available: pane, zoom: MediaZoom.fit)
            #expect(display.width <= pane.width + 0.01, "\(image) is wider than the pane")
            #expect(display.height <= pane.height + 0.01, "\(image) is taller than the pane")
        }
    }

    @Test func aLargeImageIsFittedOnItsTighterAxis() {
        let display = MediaZoom.displaySize(
            image: CGSize(width: 2048, height: 2048), available: pane, zoom: MediaZoom.fit)

        #expect(display.height == 600)
        #expect(display.width == 600)
    }

    /// A favicon stays a favicon. Fitting is capped at its true size, so the
    /// alternative — filling the pane with sixteen blurry pixels — cannot
    /// happen.
    @Test func aSmallImageIsNotBlownUpToFill() {
        let display = MediaZoom.displaySize(
            image: CGSize(width: 16, height: 16), available: pane, zoom: MediaZoom.fit)

        #expect(display == CGSize(width: 16, height: 16))
    }

    @Test func zoomMultipliesWhatFittingWouldHaveGiven() {
        let small = MediaZoom.displaySize(
            image: CGSize(width: 16, height: 16), available: pane, zoom: 2)
        #expect(small == CGSize(width: 32, height: 32))

        let large = MediaZoom.displaySize(
            image: CGSize(width: 2048, height: 2048), available: pane, zoom: 2)
        #expect(large == CGSize(width: 1200, height: 1200))
    }

    @Test func theScaleIsHowMuchOfItsTrueSizeIsOnScreen() {
        #expect(MediaZoom.scale(
            image: CGSize(width: 1600, height: 1200), available: pane, zoom: MediaZoom.fit) == 0.5)
        #expect(MediaZoom.scale(
            image: CGSize(width: 100, height: 100), available: pane, zoom: MediaZoom.fit) == 1)
    }

    // MARK: The ladder

    /// Fixed stops, so two presses in and two out land exactly back — which a
    /// multiplier does not guarantee once floating point is involved.
    @Test func zoomingInAndBackOutReturnsToWhereItStarted() {
        var zoom = MediaZoom.fit
        zoom = MediaZoom.zoomedIn(from: zoom)
        zoom = MediaZoom.zoomedIn(from: zoom)
        zoom = MediaZoom.zoomedOut(from: zoom)
        zoom = MediaZoom.zoomedOut(from: zoom)

        #expect(zoom == MediaZoom.fit)
    }

    @Test func theLadderStopsAtBothEnds() {
        var zoom = MediaZoom.fit
        for _ in 0..<20 { zoom = MediaZoom.zoomedIn(from: zoom) }
        #expect(zoom == MediaZoom.ladder[MediaZoom.ladder.count - 1])
        #expect(!MediaZoom.canZoomIn(zoom))

        for _ in 0..<40 { zoom = MediaZoom.zoomedOut(from: zoom) }
        #expect(zoom == MediaZoom.ladder[0])
        #expect(!MediaZoom.canZoomOut(zoom))
    }

    @Test func bothDirectionsAreOfferedInTheMiddle() {
        #expect(MediaZoom.canZoomIn(MediaZoom.fit))
        #expect(MediaZoom.canZoomOut(MediaZoom.fit))
    }

    @Test func fitIsOnTheLadderSoTheButtonsAgreeWithTheRestPosition() {
        #expect(MediaZoom.ladder.contains(MediaZoom.fit))
    }

    // MARK: Centring, and nonsense input

    /// The canvas is never smaller than the pane, which is what holds a small
    /// image in the middle instead of pinning it to a corner.
    @Test func theCanvasIsNeverSmallerThanThePane() {
        let canvas = MediaZoom.canvasSize(
            image: CGSize(width: 16, height: 16), available: pane, zoom: MediaZoom.fit)
        #expect(canvas == pane)
    }

    @Test func theCanvasGrowsOnlyOnTheAxisThatOverflows() {
        let canvas = MediaZoom.canvasSize(
            image: CGSize(width: 2048, height: 100), available: pane, zoom: 8)
        #expect(canvas.width > pane.width)
        #expect(canvas.height == pane.height)
    }

    /// A zero-sized image is what a half-decoded file gives back, and a NaN
    /// here would reach a frame and take AppKit down with it.
    @Test func anEmptyImageOrPaneProducesNothingStrange() {
        for (image, available) in [
            (CGSize.zero, pane),
            (CGSize(width: 100, height: 100), CGSize.zero),
            (CGSize.zero, CGSize.zero),
        ] {
            let display = MediaZoom.displaySize(image: image, available: available, zoom: 2)
            #expect(display.width.isFinite)
            #expect(display.height.isFinite)
        }
    }
}

/// The line in the bottom corner.
struct MediaInfoTests {
    @Test func anImageSaysWhatItIsAndHowBigInEveryWay() {
        let line = MediaInfo.line(
            format: "png",
            pixels: CGSize(width: 2048, height: 1024),
            bytes: 1_200_000,
            scale: 0.29)

        #expect(line.contains("PNG"))
        #expect(line.contains("2048 × 1024"))
        #expect(line.contains("29%"))

        /// The size is formatted for the machine's locale — "1.2 MB" here,
        /// "1,2 MB" on this one — which is what macOS does everywhere else and
        /// worth keeping. So the assertion is the unit and the digit, not the
        /// separator: pinning the exact string made this fail in pt-BR.
        #expect(line.contains("MB"))
        #expect(line.contains("1"))
    }

    /// Absent facts leave no gap. A file whose size could not be read draws
    /// one separator fewer, not an empty slot between two of them.
    @Test func whatCannotBeReadIsLeftOutRatherThanBlank() {
        let parts = MediaInfo.parts(format: "png", pixels: nil, bytes: nil, pages: nil, scale: nil)
        #expect(parts == ["PNG"])
        #expect(!MediaInfo.line(format: "png").contains("·"))
    }

    @Test func onePageIsSingular() {
        #expect(MediaInfo.parts(
            format: "pdf", pixels: nil, bytes: nil, pages: 1, scale: nil).contains("1 page"))
        #expect(MediaInfo.parts(
            format: "pdf", pixels: nil, bytes: nil, pages: 12, scale: nil).contains("12 pages"))
    }

    /// A big image in a small pane lands under one percent of its true size,
    /// where rounding to whole percent would report "0%".
    @Test func aVerySmallScaleStillSaysSomething() {
        let parts = MediaInfo.parts(
            format: "png", pixels: nil, bytes: nil, pages: nil, scale: 0.043)
        #expect(parts.contains("4.3%"))
    }

    @Test func aZeroSizeOrPageCountIsNotWorthSaying() {
        let parts = MediaInfo.parts(
            format: "pdf", pixels: CGSize.zero, bytes: 0, pages: 0, scale: nil)
        #expect(parts == ["PDF"])
    }
}

import AppKit
import Foundation
@testable import Ghostty
import Testing

/// How big a media file is drawn: the window-resizing bug, and what a
/// percentage means.
struct MediaZoomTests {
    private let pane = CGSize(width: 800, height: 600)
    private let huge = CGSize(width: 2048, height: 2048)
    private let tiny = CGSize(width: 16, height: 16)

    // MARK: The bug

    /// The regression, stated as the property that was violated: **fitted,
    /// nothing is ever larger than the space it has.** This is what took the
    /// app's window past the edge of the screen.
    @Test func fittedNothingIsEverLargerThanThePane() {
        let images: [CGSize] = [
            huge,
            CGSize(width: 4000, height: 900),
            CGSize(width: 900, height: 4000),
            tiny,
            CGSize(width: 801, height: 601),
        ]

        for image in images {
            let display = MediaZoom.displaySize(image: image, available: pane, level: .fit)
            #expect(display.width <= pane.width + 0.01, "\(image) is wider than the pane")
            #expect(display.height <= pane.height + 0.01, "\(image) is taller than the pane")
        }
    }

    @Test func aLargeImageIsFittedOnItsTighterAxis() {
        let display = MediaZoom.displaySize(image: huge, available: pane, level: .fit)
        #expect(display == CGSize(width: 600, height: 600))
    }

    /// A favicon stays a favicon: fitting is capped at its true size, so the
    /// alternative — filling the pane with sixteen blurry pixels — cannot
    /// happen.
    @Test func fittingNeverBlowsASmallImageUp() {
        #expect(MediaZoom.displaySize(image: tiny, available: pane, level: .fit) == tiny)
        #expect(MediaZoom.scale(.fit, image: tiny, available: pane) == 1)
    }

    // MARK: 100% is the original size

    /// The point of the whole rework. A percentage is absolute, so asking for
    /// 100% of a 2048-pixel image gives 2048 points **and scrolls** — where the
    /// first version could only offer multiples of whatever fitting happened to
    /// give, and so could never be asked for 1:1 at all.
    @Test func oneHundredPercentIsTheImagesOwnSize() {
        #expect(MediaZoom.displaySize(image: huge, available: pane, level: .scale(1)) == huge)
        #expect(MediaZoom.displaySize(image: tiny, available: pane, level: .scale(1)) == tiny)
    }

    @Test func aPercentageIsNotCappedTheWayFittingIs() {
        let display = MediaZoom.displaySize(image: tiny, available: pane, level: .scale(4))
        #expect(display == CGSize(width: 64, height: 64))
    }

    @Test func theScaleIsWhatWasAskedFor() {
        #expect(MediaZoom.scale(.scale(2), image: huge, available: pane) == 2)
        #expect(MediaZoom.scale(.fit, image: CGSize(width: 1600, height: 1200),
                                available: pane) == 0.5)
    }

    // MARK: Both limits

    @Test func zoomingInStopsAtTheCeiling() {
        var level = MediaZoom.fit
        for _ in 0..<30 { level = MediaZoom.zoomedIn(from: level, image: tiny, available: pane) }

        #expect(level == .scale(MediaZoom.maximum))
        #expect(!MediaZoom.canZoomIn(level, image: tiny, available: pane))
    }

    @Test func zoomingOutStopsAtTheFloor() {
        var level = MediaZoom.fit
        for _ in 0..<30 { level = MediaZoom.zoomedOut(from: level, image: tiny, available: pane) }

        #expect(level == .scale(MediaZoom.minimum))
        #expect(!MediaZoom.canZoomOut(level, image: tiny, available: pane))
    }

    @Test func aScaleFromOutsideTheLimitsIsBroughtInside() {
        #expect(MediaZoom.scale(.scale(400), image: tiny, available: pane) == MediaZoom.maximum)
        #expect(MediaZoom.scale(.scale(0.0001), image: tiny, available: pane) == MediaZoom.minimum)
    }

    @Test func bothDirectionsAreOfferedFromFit() {
        #expect(MediaZoom.canZoomIn(.fit, image: huge, available: pane))
        #expect(MediaZoom.canZoomOut(.fit, image: huge, available: pane))
    }

    // MARK: The ladder

    /// Absolute stops, so two presses in and two out land exactly back — which
    /// a multiplier does not guarantee once floating point is involved.
    @Test func zoomingInAndBackOutReturnsToWhereItStarted() {
        var level = MediaZoom.Level.scale(1)
        level = MediaZoom.zoomedIn(from: level, image: huge, available: pane)
        level = MediaZoom.zoomedIn(from: level, image: huge, available: pane)
        level = MediaZoom.zoomedOut(from: level, image: huge, available: pane)
        level = MediaZoom.zoomedOut(from: level, image: huge, available: pane)

        #expect(level == .scale(1))
    }

    /// Fitting a large image lands *between* stops, and a press has to take the
    /// next one from there rather than from 100% — otherwise zooming in on a
    /// screenshot fitted at 29% jumps straight past a third to full size.
    @Test func aPressStepsFromWhereTheImageActuallyIsNotFromTheLastStop() {
        let fitted = MediaZoom.scale(.fit, image: huge, available: pane)
        #expect(fitted < 0.5)

        let inwards = MediaZoom.zoomedIn(from: .fit, image: huge, available: pane)
        #expect(MediaZoom.scale(inwards, image: huge, available: pane) == 1.0 / 3)

        let outwards = MediaZoom.zoomedOut(from: .fit, image: huge, available: pane)
        #expect(MediaZoom.scale(outwards, image: huge, available: pane) == 0.25)
    }

    @Test func oneHundredPercentIsOnTheLadderSoItCanBeReachedByPressing() {
        #expect(MediaZoom.ladder.contains(1))
    }

    @Test func theLadderRunsFromTheFloorToTheCeiling() {
        #expect(MediaZoom.ladder.first == MediaZoom.minimum)
        #expect(MediaZoom.ladder.last == MediaZoom.maximum)
        #expect(MediaZoom.ladder == MediaZoom.ladder.sorted())
    }

    // MARK: Centring, and nonsense input

    /// The canvas is never smaller than the pane, which is what holds a small
    /// image in the middle instead of pinning it to a corner.
    @Test func theCanvasIsNeverSmallerThanThePane() {
        #expect(MediaZoom.canvasSize(image: tiny, available: pane, level: .fit) == pane)
    }

    @Test func theCanvasGrowsOnlyOnTheAxisThatOverflows() {
        let canvas = MediaZoom.canvasSize(
            image: CGSize(width: 2048, height: 100), available: pane, level: .scale(1))
        #expect(canvas.width > pane.width)
        #expect(canvas.height == pane.height)
    }

    /// A zero-sized image is what a half-decoded file gives back, and a NaN
    /// reaching a frame takes AppKit down with it.
    @Test func anEmptyImageOrPaneProducesNothingStrange() {
        for (image, available) in [
            (CGSize.zero, pane),
            (CGSize(width: 100, height: 100), CGSize.zero),
            (CGSize.zero, CGSize.zero),
        ] {
            for level in [MediaZoom.Level.fit, .scale(2)] {
                let display = MediaZoom.displaySize(
                    image: image, available: available, level: level)
                #expect(display.width.isFinite)
                #expect(display.height.isFinite)
            }
        }
    }

    /// A PDF is scaled by the same arithmetic, with its first page's size in
    /// place of the image's — which is what `PDFView`'s own scale factor is a
    /// proportion of, so 100% means the same thing in both.
    @Test func aPageIsScaledLikeAnImage() {
        let page = CGSize(width: 612, height: 792)
        #expect(MediaZoom.scale(.scale(1), image: page, available: pane) == 1)
        #expect(MediaZoom.scale(.fit, image: page, available: pane) < 1)
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

        /// The size is formatted for the machine's locale — "1.2 MB" in one and
        /// "1,2 MB" in another — which is what macOS does everywhere else and
        /// worth keeping. So the assertion is the unit, not the separator:
        /// pinning the exact string made this fail in pt-BR.
        #expect(line.contains("MB"))
    }

    /// Absent facts leave no gap. A file whose size could not be read draws one
    /// separator fewer, not an empty slot between two of them.
    @Test func whatCannotBeReadIsLeftOutRatherThanBlank() {
        #expect(MediaInfo.parts(
            format: "png", pixels: nil, bytes: nil, pages: nil, scale: nil) == ["PNG"])
        #expect(!MediaInfo.line(format: "png").contains("·"))
    }

    @Test func onePageIsSingular() {
        #expect(MediaInfo.parts(
            format: "pdf", pixels: nil, bytes: nil, pages: 1, scale: nil).contains("1 page"))
        #expect(MediaInfo.parts(
            format: "pdf", pixels: nil, bytes: nil, pages: 12, scale: nil).contains("12 pages"))
    }

    /// A fitted PDF says the word rather than a number, because the number
    /// would be one this code did not set.
    @Test func aFittedFileSaysFitAndAScaledOneSaysThePercentage() {
        let fitted = MediaInfo.parts(
            format: "pdf", pixels: nil, bytes: nil, pages: 3, scale: nil, fitted: true)
        #expect(fitted.contains("Fit"))

        let scaled = MediaInfo.parts(
            format: "pdf", pixels: nil, bytes: nil, pages: 3, scale: 1.5, fitted: true)
        #expect(scaled.contains("150%"))
        #expect(!scaled.contains("Fit"), "a scale that was asked for is not a fit")
    }

    /// A big image in a small pane lands under one percent of its true size,
    /// where rounding to whole percent would report "0%".
    @Test func aVerySmallScaleStillSaysSomething() {
        #expect(MediaInfo.parts(
            format: "png", pixels: nil, bytes: nil, pages: nil, scale: 0.043).contains("4.3%"))
    }

    @Test func aZeroSizeOrPageCountIsNotWorthSaying() {
        #expect(MediaInfo.parts(
            format: "pdf", pixels: CGSize.zero, bytes: 0, pages: 0, scale: nil) == ["PDF"])
    }
}
